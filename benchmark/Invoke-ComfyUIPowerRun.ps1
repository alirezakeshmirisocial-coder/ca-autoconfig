[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkflowPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
    [string]$WorkflowId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}$')]
    [string]$ModelLabel,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,31}$')]
    [string]$Quantization,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,95}$')]
    [string]$BackendLabel = 'ComfyUI local API',

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]{1,128}$')]
    [string]$SeedNodeId,

    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')]
    [string]$SeedInputName = 'seed',

    [ValidateRange(0, 9223372036854775806)]
    [long]$BaseSeed = 42,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 1000000)]
    [int]$WorkUnits,

    [ValidateSet('image')]
    [string]$WorkUnit = 'image',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GpuIndexList,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [uri]$ComfyUIBaseUri = 'http://127.0.0.1:8188',

    [ValidateRange(250, 5000)]
    [int]$IntervalMilliseconds = 500,

    [ValidateRange(1, 3600)]
    [int]$MinimumMeasuredSeconds = 5,

    [ValidateRange(10, 7200)]
    [int]$TimeoutSeconds = 900,

    [ValidateRange(1, 120)]
    [int]$RequestTimeoutSeconds = 30,

    [ValidateRange(1, 1000)]
    [int]$Repetition = 1,

    [string]$NvidiaSmiPath = (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),

    [switch]$AllowRemoteEndpoint,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PowerCurve.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ComfyUIAdapter.psm1') -Force
Add-Type -AssemblyName System.Net.Http

if ($ComfyUIBaseUri.Scheme -notin @('http', 'https')) { throw 'ComfyUIBaseUri must use http or https.' }
$endpointAddresses = @([Net.Dns]::GetHostAddresses($ComfyUIBaseUri.DnsSafeHost))
$isLoopbackEndpoint = $endpointAddresses.Count -gt 0 -and @($endpointAddresses | Where-Object { -not [Net.IPAddress]::IsLoopback($_) }).Count -eq 0
if (-not $isLoopbackEndpoint -and -not $AllowRemoteEndpoint) {
    throw 'The ComfyUI endpoint is not loopback. Refusing to send the workflow unless -AllowRemoteEndpoint is explicit.'
}
if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) { throw "ComfyUI API workflow was not found: $WorkflowPath" }
if (-not (Test-Path -LiteralPath $NvidiaSmiPath -PathType Leaf)) { throw "nvidia-smi was not found: $NvidiaSmiPath" }
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) { throw "Output already exists: $OutputPath. Use -Force to replace it." }

$workflowJson = Get-Content -Raw -LiteralPath $WorkflowPath
$workflow = ConvertFrom-CAComfyWorkflowJson -Json $workflowJson
$warmupWorkflow = New-CAComfySeededWorkflow -Workflow $workflow -SeedNodeId $SeedNodeId -SeedInputName $SeedInputName -Seed $BaseSeed
$measuredWorkflow = New-CAComfySeededWorkflow -Workflow $workflow -SeedNodeId $SeedNodeId -SeedInputName $SeedInputName -Seed ($BaseSeed + 1)

$gpuIndexes = @()
foreach ($token in @($GpuIndexList -split ',')) {
    $index = 0
    if ([string]::IsNullOrWhiteSpace($token) -or -not [int]::TryParse($token.Trim(), [ref]$index) -or $index -lt 0) {
        throw "Invalid GPU index list '$GpuIndexList'. Use a comma-separated list such as 0,1."
    }
    $gpuIndexes += $index
}
if (@($gpuIndexes | Select-Object -Unique).Count -ne $gpuIndexes.Count) { throw 'GPU indices must not contain duplicates.' }

function ConvertTo-NullableDouble {
    param($Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or $text -match '^(N/A|\[N/A\]|Not Supported)$') { return $null }
    $number = 0.0
    if (-not [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
    return $number
}

function Read-GpuTelemetry {
    param([Parameter(Mandatory = $true)][int]$Index)
    $arguments = @(
        '-i', [string]$Index,
        '--query-gpu=index,name,driver_version,power.limit,power.draw,temperature.gpu,utilization.gpu,memory.used,memory.total,clocks.gr',
        '--format=csv,noheader,nounits'
    )
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& $NvidiaSmiPath @arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    if ($exitCode -ne 0) { throw "nvidia-smi telemetry query for GPU $Index failed with exit code ${exitCode}: $output" }
    $rows = @($output | ConvertFrom-Csv -Header @('Index', 'Name', 'Driver', 'PowerLimit', 'PowerDraw', 'Temperature', 'Utilization', 'MemoryUsed', 'MemoryTotal', 'Clock'))
    if ($rows.Count -ne 1 -or [int]$rows[0].Index -ne $Index) { throw "Unexpected nvidia-smi response for GPU ${Index}: $output" }
    return $rows[0]
}

function New-JsonContent {
    param([Parameter(Mandatory = $true)]$Body)
    $json = $Body | ConvertTo-Json -Depth 100 -Compress
    return [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
}

function Read-JsonResponse {
    param([Parameter(Mandatory = $true)][Net.Http.HttpResponseMessage]$Response, [Parameter(Mandatory = $true)][string]$Operation)
    if (-not $Response.IsSuccessStatusCode) { throw "ComfyUI $Operation failed with HTTP $([int]$Response.StatusCode)." }
    $text = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ([string]::IsNullOrWhiteSpace($text)) { throw "ComfyUI $Operation returned an empty response." }
    return $text | ConvertFrom-Json
}

function Invoke-ComfyGet {
    param([Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client, [Parameter(Mandatory = $true)][uri]$Uri, [Parameter(Mandatory = $true)][string]$Operation)
    $response = $Client.GetAsync($Uri).GetAwaiter().GetResult()
    try { return Read-JsonResponse -Response $response -Operation $Operation }
    finally { $response.Dispose() }
}

function Invoke-ComfyPost {
    param([Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client, [Parameter(Mandatory = $true)][uri]$Uri, [Parameter(Mandatory = $true)]$Body, [Parameter(Mandatory = $true)][string]$Operation)
    $content = New-JsonContent -Body $Body
    try {
        $response = $Client.PostAsync($Uri, $content).GetAwaiter().GetResult()
        try { return Read-JsonResponse -Response $response -Operation $Operation }
        finally { $response.Dispose() }
    }
    finally { $content.Dispose() }
}

$base = $ComfyUIBaseUri.AbsoluteUri.TrimEnd('/')
$httpHandler = [Net.Http.HttpClientHandler]::new()
$httpHandler.AllowAutoRedirect = $false
$client = [Net.Http.HttpClient]::new($httpHandler)
$client.Timeout = [TimeSpan]::FromSeconds($RequestTimeoutSeconds)
$clientId = [Guid]::NewGuid().ToString()
try {
    function Assert-ComfyQueueEmpty {
        $queueDocument = Invoke-ComfyGet -Client $client -Uri ([uri]"$base/queue") -Operation 'queue query'
        $counts = Get-CAComfyQueueCounts -Response $queueDocument
        if ($counts.Running -ne 0 -or $counts.Pending -ne 0) {
            throw 'ComfyUI already has running or pending work. Wait for an empty queue before benchmarking.'
        }
    }

    function Submit-ComfyWorkflow {
        param([Parameter(Mandatory = $true)]$RunWorkflow)
        $queueDocument = Invoke-ComfyPost -Client $client -Uri ([uri]"$base/prompt") -Operation 'workflow submission' -Body ([ordered]@{
            prompt = $RunWorkflow
            client_id = $clientId
        })
        return ConvertFrom-CAComfyQueueResponse -Response $queueDocument
    }

    function Wait-ComfyWorkflow {
        param(
            [Parameter(Mandatory = $true)][string]$PromptId,
            [switch]$RejectSeedNodeCache
        )
        $clock = [Diagnostics.Stopwatch]::StartNew()
        do {
            $history = Invoke-ComfyGet -Client $client -Uri ([uri]"$base/history/$PromptId") -Operation 'history query'
            $status = Get-CAComfyHistoryResult -Response $history -PromptId $PromptId -SeedNodeId $SeedNodeId -RejectSeedNodeCache:$RejectSeedNodeCache
            if ($status.State -ne 'pending') {
                $clock.Stop()
                return [pscustomobject]@{ Status = $status; Elapsed = $clock.Elapsed }
            }
            Start-Sleep -Milliseconds $IntervalMilliseconds
        } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
        $clock.Stop()
        return [pscustomobject]@{ Status = [pscustomobject]@{ State = 'failed'; Reason = 'timeout'; SeedNodeCached = $false; OutputImageCount = $null }; Elapsed = $clock.Elapsed }
    }

    Assert-ComfyQueueEmpty
    $warmupClock = [Diagnostics.Stopwatch]::StartNew()
    $warmupPromptId = Submit-ComfyWorkflow -RunWorkflow $warmupWorkflow
    $warmup = Wait-ComfyWorkflow -PromptId $warmupPromptId
    $warmupClock.Stop()
    if ($warmup.Status.State -ne 'passed' -or [int]$warmup.Status.OutputImageCount -ne $WorkUnits) {
        throw 'ComfyUI warm-up did not complete with the declared number of image outputs.'
    }
    Assert-ComfyQueueEmpty

    $gpuData = [ordered]@{}
    foreach ($index in $gpuIndexes) {
        $inventory = Read-GpuTelemetry -Index $index
        $gpuData[[string]$index] = [ordered]@{
            index           = $index
            model           = ([string]$inventory.Name).Trim()
            driver          = ([string]$inventory.Driver).Trim()
            powerLimitWatts = ConvertTo-NullableDouble $inventory.PowerLimit
            samples         = New-Object Collections.Generic.List[object]
        }
    }

    $measurementStartedUtc = [DateTime]::UtcNow
    $measureClock = [Diagnostics.Stopwatch]::StartNew()
    $measuredPromptId = Submit-ComfyWorkflow -RunWorkflow $measuredWorkflow
    $sampleIndex = 0
    $measureStatus = $null
    do {
        foreach ($index in $gpuIndexes) {
            $row = Read-GpuTelemetry -Index $index
            $gpuData[[string]$index].samples.Add([pscustomobject][ordered]@{
                elapsedMilliseconds = [int][Math]::Round($measureClock.Elapsed.TotalMilliseconds)
                powerDrawWatts      = ConvertTo-NullableDouble $row.PowerDraw
                temperatureC        = ConvertTo-NullableDouble $row.Temperature
                utilizationPercent  = ConvertTo-NullableDouble $row.Utilization
                memoryUsedMiB       = ConvertTo-NullableDouble $row.MemoryUsed
                memoryTotalMiB      = ConvertTo-NullableDouble $row.MemoryTotal
                graphicsClockMHz    = ConvertTo-NullableDouble $row.Clock
            })
        }
        try {
            $history = Invoke-ComfyGet -Client $client -Uri ([uri]"$base/history/$measuredPromptId") -Operation 'measured history query'
            $measureStatus = Get-CAComfyHistoryResult -Response $history -PromptId $measuredPromptId -SeedNodeId $SeedNodeId -RejectSeedNodeCache
        }
        catch {
            $measureStatus = [pscustomobject]@{ State = 'failed'; Reason = 'history-query-failed'; SeedNodeCached = $false; OutputImageCount = $null }
        }
        if ($measureStatus.State -ne 'pending') { break }
        $sampleIndex++
        $remaining = ($sampleIndex * $IntervalMilliseconds) - [int][Math]::Round($measureClock.Elapsed.TotalMilliseconds)
        if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
    } while ($measureClock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $measureClock.Stop()
    $measurementEndedUtc = [DateTime]::UtcNow

    if ($null -eq $measureStatus -or $measureStatus.State -eq 'pending') {
        $resultStatus = 'failed'
        $resultError = 'The measured ComfyUI workflow exceeded the timeout. The adapter did not call the global interrupt endpoint.'
        $workUnitsPerSecond = $null
    }
    elseif ($measureStatus.State -eq 'failed' -or [int]$measureStatus.OutputImageCount -ne $WorkUnits) {
        $resultStatus = 'failed'
        $resultError = if ($measureStatus.Reason -eq 'seed-node-cached') {
            'The configured seed node was cached; choose a seed binding that invalidates the measured sampler path.'
        } elseif ($measureStatus.State -eq 'passed') {
            'The measured ComfyUI workflow did not produce the declared number of image outputs.'
        } else {
            'The measured ComfyUI workflow failed or returned invalid terminal evidence.'
        }
        $workUnitsPerSecond = $null
    }
    else {
        $workUnitsPerSecond = [Math]::Round($WorkUnits / $measureClock.Elapsed.TotalSeconds, 9)
        if ($measureClock.Elapsed.TotalSeconds -lt $MinimumMeasuredSeconds) {
            $resultStatus = 'incomplete'
            $resultError = 'The measured workflow ended before the configured minimum window; use a larger fixed workflow or batch.'
        }
        else {
            $resultStatus = 'passed'
            $resultError = $null
        }
    }

    $gpus = foreach ($index in $gpuIndexes) {
        $gpu = $gpuData[[string]$index]
        [pscustomobject][ordered]@{
            index           = $gpu.index
            model           = $gpu.model
            driver          = $gpu.driver
            powerLimitWatts = $gpu.powerLimitWatts
            samples         = $gpu.samples.ToArray()
        }
    }

    $run = [pscustomobject][ordered]@{
        schemaVersion = 3
        runId         = 'run-' + [Guid]::NewGuid().ToString('N')
        createdUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        source        = 'live'
        privacy       = [pscustomobject][ordered]@{
            containsGpuUuid     = $false
            containsMachineName = $false
            containsUserName    = $false
            containsPaths       = $false
            containsRawCommand  = $false
        }
        workload      = [pscustomobject][ordered]@{
            class        = 'comfyui'
            name         = "$WorkflowId · ComfyUI · $WorkUnits $WorkUnit/run · seed=$SeedNodeId.$SeedInputName · client-window"
            model        = $ModelLabel
            quantization = $Quantization
            backend      = $BackendLabel
        }
        protocol      = [pscustomobject][ordered]@{
            warmupSeconds        = [int][Math]::Ceiling($warmupClock.Elapsed.TotalSeconds)
            sampleSeconds        = [int][Math]::Max(1, [Math]::Ceiling($measureClock.Elapsed.TotalSeconds))
            intervalMilliseconds = $IntervalMilliseconds
            repetition           = $Repetition
        }
        measurement   = [pscustomobject][ordered]@{
            powerWindow          = 'client-window'
            promptRateWindow     = $null
            generationRateWindow = $null
            workRateWindow       = if ($null -eq $workUnitsPerSecond) { $null } else { 'client-window' }
            startedUtc           = $measurementStartedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            endedUtc             = $measurementEndedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
        result        = [pscustomobject][ordered]@{
            status     = $resultStatus
            throughput = [pscustomobject][ordered]@{
                promptTokensPerSecond     = $null
                generationTokensPerSecond = $null
                workUnitsPerSecond        = $workUnitsPerSecond
                workUnit                  = if ($null -eq $workUnitsPerSecond) { $null } else { $WorkUnit }
            }
            error      = $resultError
        }
        gpus          = @($gpus)
    }

    Assert-CAPowerCurveRun -Run $run | Out-Null
    $fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $fullOutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }
    $run | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $fullOutputPath -Encoding UTF8

    [pscustomobject]@{
        Status                    = if ($resultStatus -eq 'passed') { 'Recorded' } elseif ($resultStatus -eq 'incomplete') { 'RecordedIncomplete' } else { 'RecordedFailed' }
        Output                    = $fullOutputPath
        RunId                     = $run.runId
        Model                     = $ModelLabel
        Quantization              = $Quantization
        WorkUnitsPerSecond        = $workUnitsPerSecond
        WorkUnit                  = if ($null -eq $workUnitsPerSecond) { $null } else { $WorkUnit }
        MeasuredSeconds           = [Math]::Round($measureClock.Elapsed.TotalSeconds, 3)
        SamplesPerGpu             = @($gpus[0].samples).Count
        HardwareWrites            = $false
        ContainsWorkflowOrOutputs = $false
    }
}
finally { $client.Dispose() }
