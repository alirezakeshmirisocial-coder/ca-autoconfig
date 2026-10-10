Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CAComfyPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Optional
    )

    if ($null -eq $Object) {
        if ($Optional) { return $null }
        throw "ComfyUI response is missing '$Name'."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        if ($Optional) { return $null }
        throw "ComfyUI response is missing '$Name'."
    }
    return ,$property.Value
}

function ConvertFrom-CAComfyWorkflowJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Json)

    try { $workflow = $Json | ConvertFrom-Json }
    catch { throw 'The ComfyUI workflow is not valid JSON.' }
    if ($null -eq $workflow -or $workflow -is [Array] -or $workflow -isnot [pscustomobject]) { throw 'The ComfyUI API workflow contains no nodes.' }
    $nodes = @($workflow.PSObject.Properties)
    if ($nodes.Count -lt 1) { throw 'The ComfyUI API workflow contains no nodes.' }
    foreach ($nodeProperty in $nodes) {
        $node = $nodeProperty.Value
        $classProperty = if ($null -eq $node) { $null } else { $node.PSObject.Properties['class_type'] }
        $inputsProperty = if ($null -eq $node) { $null } else { $node.PSObject.Properties['inputs'] }
        if ($null -eq $classProperty -or $null -eq $inputsProperty -or
            [string]::IsNullOrWhiteSpace([string]$classProperty.Value) -or $null -eq $inputsProperty.Value) {
            throw "ComfyUI node '$($nodeProperty.Name)' is not in API workflow format."
        }
    }
    return $workflow
}

function New-CAComfySeededWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Workflow,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$SeedNodeId,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')][string]$SeedInputName,
        [Parameter(Mandatory = $true)][ValidateRange(0, 9223372036854775807)][long]$Seed
    )

    $copy = $Workflow | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json
    $nodeProperty = $copy.PSObject.Properties[$SeedNodeId]
    if ($null -eq $nodeProperty) { throw "ComfyUI seed node '$SeedNodeId' does not exist." }
    $inputs = Get-CAComfyPropertyValue -Object $nodeProperty.Value -Name 'inputs'
    $seedProperty = $inputs.PSObject.Properties[$SeedInputName]
    if ($null -eq $seedProperty) { throw "ComfyUI seed input '$SeedNodeId.$SeedInputName' does not exist." }
    $existingSeed = 0L
    if (-not [long]::TryParse([string]$seedProperty.Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$existingSeed)) {
        throw "ComfyUI seed input '$SeedNodeId.$SeedInputName' is not an integer."
    }
    $seedProperty.Value = $Seed
    return $copy
}

function ConvertFrom-CAComfyQueueResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Response)

    $promptId = ([string](Get-CAComfyPropertyValue -Object $Response -Name 'prompt_id')).Trim()
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($promptId, [ref]$parsed)) { throw 'ComfyUI queue response contains an invalid prompt_id.' }
    return $promptId
}

function Get-CAComfyQueueCounts {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Response)

    $running = Get-CAComfyPropertyValue -Object $Response -Name 'queue_running'
    $pending = Get-CAComfyPropertyValue -Object $Response -Name 'queue_pending'
    [pscustomobject]@{
        Running = @($running).Count
        Pending = @($pending).Count
    }
}

function Get-CAComfyHistoryResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$PromptId,
        [string]$SeedNodeId = '',
        [switch]$RejectSeedNodeCache
    )

    $entryProperty = $Response.PSObject.Properties[$PromptId]
    if ($null -eq $entryProperty) {
        return [pscustomobject]@{ State = 'pending'; Reason = $null; SeedNodeCached = $false; OutputImageCount = $null }
    }
    $status = Get-CAComfyPropertyValue -Object $entryProperty.Value -Name 'status'
    $completed = Get-CAComfyPropertyValue -Object $status -Name 'completed'
    if (-not [bool]$completed) {
        return [pscustomobject]@{ State = 'pending'; Reason = $null; SeedNodeCached = $false; OutputImageCount = $null }
    }

    $seedNodeCached = $false
    $messages = Get-CAComfyPropertyValue -Object $status -Name 'messages' -Optional
    foreach ($message in @($messages)) {
        if ($null -eq $message -or @($message).Count -lt 2 -or [string]$message[0] -ne 'execution_cached') { continue }
        $nodes = Get-CAComfyPropertyValue -Object $message[1] -Name 'nodes' -Optional
        if (-not [string]::IsNullOrWhiteSpace($SeedNodeId) -and @($nodes | ForEach-Object { [string]$_ }) -contains $SeedNodeId) {
            $seedNodeCached = $true
        }
    }
    if ($RejectSeedNodeCache -and $seedNodeCached) {
        return [pscustomobject]@{ State = 'failed'; Reason = 'seed-node-cached'; SeedNodeCached = $true; OutputImageCount = $null }
    }

    $statusText = ([string](Get-CAComfyPropertyValue -Object $status -Name 'status_str')).Trim().ToLowerInvariant()
    if ($statusText -eq 'success') {
        $outputImageCount = 0
        $outputs = Get-CAComfyPropertyValue -Object $entryProperty.Value -Name 'outputs' -Optional
        if ($null -ne $outputs) {
            foreach ($outputProperty in @($outputs.PSObject.Properties)) {
                $images = Get-CAComfyPropertyValue -Object $outputProperty.Value -Name 'images' -Optional
                if ($null -ne $images) { $outputImageCount += @($images).Count }
            }
        }
        return [pscustomobject]@{ State = 'passed'; Reason = $null; SeedNodeCached = $seedNodeCached; OutputImageCount = $outputImageCount }
    }
    return [pscustomobject]@{ State = 'failed'; Reason = 'execution-failed'; SeedNodeCached = $seedNodeCached; OutputImageCount = $null }
}

Export-ModuleMember -Function @(
    'ConvertFrom-CAComfyWorkflowJson',
    'New-CAComfySeededWorkflow',
    'ConvertFrom-CAComfyQueueResponse',
    'Get-CAComfyQueueCounts',
    'Get-CAComfyHistoryResult'
)
