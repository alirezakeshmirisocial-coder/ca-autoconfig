[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComfyUIAdapter.psm1') -Force

$passed = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:passed++
    Write-Host "PASS $Name" -ForegroundColor Green
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern, [string]$Message)
    $thrown = $false
    try { & $Body }
    catch {
        $thrown = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Message Unexpected error: $($_.Exception.Message)" }
    }
    if (-not $thrown) { throw $Message }
}

$workflowJson = '{"3":{"class_type":"KSampler","inputs":{"seed":42,"steps":20,"text":"private prompt"}},"9":{"class_type":"SaveImage","inputs":{"images":["3",0],"filename_prefix":"private-output"}}}'

Test-Case 'API workflow parsing requires nodes with class type and inputs' {
    $workflow = ConvertFrom-CAComfyWorkflowJson -Json $workflowJson
    Assert-True ([string]$workflow.'3'.class_type -eq 'KSampler') 'Valid API workflow was not parsed.'
    Assert-Throws { ConvertFrom-CAComfyWorkflowJson -Json '{"nodes":[]}' } 'not in API workflow format' 'A frontend workflow was accepted as API format.'
    Assert-Throws { ConvertFrom-CAComfyWorkflowJson -Json '[]' } 'contains no nodes' 'An empty workflow was accepted.'
}

Test-Case 'seed injection clones the workflow and preserves private content in memory only' {
    $workflow = ConvertFrom-CAComfyWorkflowJson -Json $workflowJson
    $seeded = New-CAComfySeededWorkflow -Workflow $workflow -SeedNodeId '3' -SeedInputName 'seed' -Seed 99
    Assert-True ([long]$seeded.'3'.inputs.seed -eq 99) 'Configured seed was not injected.'
    Assert-True ([long]$workflow.'3'.inputs.seed -eq 42) 'Seed injection mutated the source workflow.'
    Assert-True ([string]$seeded.'3'.inputs.text -eq 'private prompt') 'Workflow clone changed unrelated inputs.'
}

Test-Case 'missing or non-integer seed bindings fail closed' {
    $workflow = ConvertFrom-CAComfyWorkflowJson -Json $workflowJson
    Assert-Throws { New-CAComfySeededWorkflow -Workflow $workflow -SeedNodeId 'missing' -SeedInputName 'seed' -Seed 1 } 'does not exist' 'Missing seed node was accepted.'
    Assert-Throws { New-CAComfySeededWorkflow -Workflow $workflow -SeedNodeId '3' -SeedInputName 'noise_seed' -Seed 1 } 'does not exist' 'Missing seed input was accepted.'
    $workflow.'3'.inputs.seed = 'randomize'
    Assert-Throws { New-CAComfySeededWorkflow -Workflow $workflow -SeedNodeId '3' -SeedInputName 'seed' -Seed 1 } 'not an integer' 'Non-integer seed binding was accepted.'
}

Test-Case 'queue response and empty-queue evidence are validated' {
    $id = '00000000-0000-0000-0000-000000000001'
    Assert-True ((ConvertFrom-CAComfyQueueResponse -Response ([pscustomobject]@{ prompt_id = $id })) -eq $id) 'Valid prompt_id was changed.'
    Assert-Throws { ConvertFrom-CAComfyQueueResponse -Response ([pscustomobject]@{ prompt_id = 'private/path' }) } 'invalid prompt_id' 'Unsafe prompt_id was accepted.'
    $counts = Get-CAComfyQueueCounts -Response ([pscustomobject]@{ queue_running = @(); queue_pending = @(@('job')) })
    Assert-True ([int]$counts.Running -eq 0 -and [int]$counts.Pending -eq 1) 'Queue counts are wrong.'
}

Test-Case 'history parsing distinguishes pending, success, error, and cached seed nodes' {
    $id = '00000000-0000-0000-0000-000000000002'
    Assert-True ((Get-CAComfyHistoryResult -Response ([pscustomobject]@{}) -PromptId $id).State -eq 'pending') 'Missing history was not pending.'
    $successEntry = [pscustomobject]@{
        status = [pscustomobject]@{
            status_str = 'success'; completed = $true
            messages = @(
                ,([object[]]@('execution_cached', [pscustomobject]@{ nodes = @('4') }))
                ,([object[]]@('execution_success', [pscustomobject]@{}))
            )
        }
    }
    $successDoc = [pscustomobject]@{}
    $successDoc | Add-Member -NotePropertyName $id -NotePropertyValue $successEntry
    $success = Get-CAComfyHistoryResult -Response $successDoc -PromptId $id -SeedNodeId '3' -RejectSeedNodeCache
    Assert-True ($success.State -eq 'passed' -and -not $success.SeedNodeCached) 'Valid terminal history did not pass.'
    $successEntry.status.messages = @(,([object[]]@('execution_cached', [pscustomobject]@{ nodes = @('3', '4') })))
    $cached = Get-CAComfyHistoryResult -Response $successDoc -PromptId $id -SeedNodeId '3' -RejectSeedNodeCache
    Assert-True ($cached.State -eq 'failed' -and $cached.Reason -eq 'seed-node-cached') 'Cached measured seed node was accepted.'
    $successEntry.status.status_str = 'error'
    $successEntry.status.messages = @()
    Assert-True ((Get-CAComfyHistoryResult -Response $successDoc -PromptId $id).State -eq 'failed') 'Error history was accepted.'
}

Test-Case 'live adapter is loopback-first, query-only, and never fetches outputs' {
    $source = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Invoke-ComfyUIPowerRun.ps1')
    Assert-True ($source -match 'IPAddress\]::IsLoopback' -and $source -match 'AllowRemoteEndpoint') 'Remote workflow safety gate is missing.'
    Assert-True ($source -match 'AllowAutoRedirect\s*=\s*\$false') 'Loopback workflow requests may follow a redirect to another host.'
    Assert-True ($source -match '/prompt' -and $source -match '/history/' -and $source -match '/queue') 'Required official ComfyUI routes are missing.'
    Assert-True ($source -notmatch '/view|/interrupt|/free|/models|Invoke-WebRequest|Start-BitsTransfer') 'Adapter downloads outputs, changes server state globally, or contains a downloader.'
    Assert-True ($source -match '--query-gpu=' -and $source -notmatch '(?i)[''"]-(pl|lgc|rgc|ac)[''"]') 'Adapter contains a GPU mutation path.'
    Assert-True ($source -notmatch 'Start-ScheduledTask|Register-ScheduledTask|Verb\s+RunAs') 'Adapter contains elevation or scheduled-task control.'
    Assert-True ($source -match 'ContainsWorkflowOrOutputs\s+=\s+\$false') 'Adapter does not explicitly report workflow/output omission.'
}

Test-Case 'non-loopback endpoint is rejected before workflow or hardware access' {
    $temporaryOutput = Join-Path ([IO.Path]::GetTempPath()) ('ca-comfy-remote-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Invoke-ComfyUIPowerRun.ps1') `
                -WorkflowPath 'missing-private-workflow.json' `
                -WorkflowId 'fixture-v1' `
                -ModelLabel 'Fixture model' `
                -Quantization 'FP16' `
                -SeedNodeId '3' `
                -WorkUnits 1 `
                -GpuIndexList '0' `
                -OutputPath $temporaryOutput `
                -ComfyUIBaseUri 'http://192.0.2.1:8188' `
                -NvidiaSmiPath 'missing-nvidia-smi.exe'
        } 'not loopback' 'A remote endpoint was not rejected before workflow or GPU access.'
        Assert-True (-not (Test-Path -LiteralPath $temporaryOutput)) 'Remote rejection created an export.'
    }
    finally { Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue }
}

Test-Case 'local ComfyUI fixture records work rate while stripping workflow and outputs' {
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('ca-comfy-adapter-' + [Guid]::NewGuid().ToString('N'))
    $listenerProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listenerProbe.Start()
    $port = ([Net.IPEndPoint]$listenerProbe.LocalEndpoint).Port
    $listenerProbe.Stop()
    $serverJob = $null
    try {
        New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
        $workflowPath = Join-Path $temporaryRoot 'private workflow.json'
        $seedLogPath = Join-Path $temporaryRoot 'seeds.txt'
        $fakeNvidiaSmi = Join-Path $temporaryRoot 'nvidia-smi.cmd'
        Set-Content -LiteralPath $workflowPath -Value $workflowJson -Encoding UTF8
        Set-Content -LiteralPath $fakeNvidiaSmi -Encoding Ascii -Value @(
            '@echo off',
            'echo 0, NVIDIA GeForce RTX TEST, 999.0, 250.00, 200.00, 55, 90, 10000, 24000, 1500',
            'exit /b 0'
        )
        $serverJob = Start-Job -ArgumentList $port, $seedLogPath -ScriptBlock {
            param($Port, $SeedLogPath)
            $listener = [Net.HttpListener]::new()
            $listener.Prefixes.Add("http://127.0.0.1:$Port/")
            $listener.Start()
            $submissionCount = 0
            $historyPolls = @{}
            try {
                while ($true) {
                    $context = $listener.GetContext()
                    $path = $context.Request.Url.AbsolutePath
                    $responseObject = $null
                    $stopAfterResponse = $false
                    if ($context.Request.HttpMethod -eq 'GET' -and $path -eq '/queue') {
                        $responseObject = [ordered]@{ queue_running = @(); queue_pending = @() }
                    }
                    elseif ($context.Request.HttpMethod -eq 'POST' -and $path -eq '/prompt') {
                        $reader = New-Object IO.StreamReader($context.Request.InputStream, $context.Request.ContentEncoding)
                        try { $body = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                        $submissionCount++
                        Add-Content -LiteralPath $SeedLogPath -Value ([string]$body.prompt.'3'.inputs.seed) -Encoding ASCII
                        $promptId = '00000000-0000-0000-0000-' + $submissionCount.ToString('000000000000')
                        $responseObject = [ordered]@{ prompt_id = $promptId; number = $submissionCount; node_errors = [ordered]@{} }
                    }
                    elseif ($context.Request.HttpMethod -eq 'GET' -and $path -like '/history/*') {
                        $promptId = $path.Substring('/history/'.Length)
                        if (-not $historyPolls.ContainsKey($promptId)) { $historyPolls[$promptId] = 0 }
                        $historyPolls[$promptId]++
                        $ordinal = [int]$promptId.Substring($promptId.Length - 12)
                        $terminal = ($ordinal -in @(1, 3, 5)) -or ($ordinal -eq 2 -and $historyPolls[$promptId] -ge 5) -or ($ordinal -in @(4, 6) -and $historyPolls[$promptId] -ge 4)
                        if (-not $terminal) {
                            $responseObject = [ordered]@{}
                        }
                        else {
                            $statusText = if ($ordinal -eq 6) { 'error' } else { 'success' }
                            $messages = New-Object Collections.Generic.List[object]
                            if ($ordinal -eq 6) {
                                $messages.Add([object[]]@('execution_error', [ordered]@{ exception_message = 'private server error'; node_id = '3' }))
                            } else {
                                $messages.Add([object[]]@('execution_cached', [ordered]@{ nodes = @('4') }))
                                $messages.Add([object[]]@('execution_success', [ordered]@{}))
                            }
                            $entry = [ordered]@{
                                status = [ordered]@{ status_str = $statusText; completed = $true; messages = $messages }
                                outputs = [ordered]@{ '9' = [ordered]@{ images = if ($ordinal -eq 4) {
                                    @([ordered]@{ filename = 'private-output-1.png'; subfolder = 'private/path'; type = 'output' })
                                } else {
                                    @(
                                        [ordered]@{ filename = 'private-output-1.png'; subfolder = 'private/path'; type = 'output' },
                                        [ordered]@{ filename = 'private-output-2.png'; subfolder = 'private/path'; type = 'output' }
                                    )
                                } } }
                                prompt = @('private workflow and prompt must not be exported')
                            }
                            $responseObject = [ordered]@{}
                            $responseObject[$promptId] = $entry
                            if ($ordinal -eq 6) { $stopAfterResponse = $true }
                        }
                    }
                    else {
                        $context.Response.StatusCode = 404
                        $responseObject = [ordered]@{ error = 'private route detail' }
                    }
                    $responseText = $responseObject | ConvertTo-Json -Depth 12 -Compress
                    $bytes = [Text.Encoding]::UTF8.GetBytes($responseText)
                    $context.Response.ContentType = 'application/json'
                    $context.Response.ContentLength64 = $bytes.Length
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $context.Response.OutputStream.Close()
                    if ($stopAfterResponse) { break }
                }
            }
            finally { $listener.Stop() }
        }

        $baseUri = "http://127.0.0.1:$port"
        $ready = $false
        for ($attempt = 0; $attempt -lt 40 -and -not $ready; $attempt++) {
            try {
                $null = Invoke-WebRequest -UseBasicParsing -Uri "$baseUri/queue" -TimeoutSec 1
                $ready = $true
            }
            catch {
                if ($serverJob.State -in @('Failed', 'Stopped', 'Completed')) { break }
                Start-Sleep -Milliseconds 100
            }
        }
        Assert-True $ready 'Local ComfyUI fixture server did not become ready.'

        $outputPath = Join-Path $temporaryRoot 'run.json'
        $result = & (Join-Path $PSScriptRoot 'Invoke-ComfyUIPowerRun.ps1') `
            -WorkflowPath $workflowPath `
            -WorkflowId 'fixture-v1' `
            -ModelLabel 'Fixture diffusion model' `
            -Quantization 'FP16' `
            -BackendLabel 'ComfyUI fixture API' `
            -SeedNodeId '3' `
            -BaseSeed 100 `
            -WorkUnits 2 `
            -WorkUnit 'image' `
            -GpuIndexList '0' `
            -OutputPath $outputPath `
            -ComfyUIBaseUri $baseUri `
            -IntervalMilliseconds 250 `
            -MinimumMeasuredSeconds 1 `
            -TimeoutSeconds 10 `
            -RequestTimeoutSeconds 5 `
            -NvidiaSmiPath $fakeNvidiaSmi
        $rawRun = Get-Content -Raw -LiteralPath $outputPath
        $run = $rawRun | ConvertFrom-Json
        Assert-True ([string]$result.Status -eq 'Recorded' -and [int]$run.schemaVersion -eq 3 -and [string]$run.result.status -eq 'passed') 'Valid ComfyUI fixture run was not recorded.'
        Assert-True ([string]$run.measurement.powerWindow -eq 'client-window' -and [string]$run.measurement.workRateWindow -eq 'client-window') 'ComfyUI output lost same-window energy provenance.'
        Assert-True ([DateTime]$run.measurement.endedUtc -gt [DateTime]$run.measurement.startedUtc) 'ComfyUI output lost its explicit measurement window.'
        Assert-True ([double]$run.result.throughput.workUnitsPerSecond -gt 0 -and [string]$run.result.throughput.workUnit -eq 'image') 'Work-unit throughput was not recorded.'
        Assert-True (@($run.gpus[0].samples).Count -ge 5) 'ComfyUI execution was not sampled concurrently.'
        Assert-True ($rawRun -notmatch 'private prompt|private-output|private/path|private workflow|workflowPath|prompt_id') 'Workflow, output, path, or prompt identity leaked into the export.'
        Assert-True (-not [bool]$result.HardwareWrites -and -not [bool]$result.ContainsWorkflowOrOutputs) 'Adapter reported a privacy or hardware-write violation.'

        $mismatchPath = Join-Path $temporaryRoot 'mismatch.json'
        $mismatchResult = & (Join-Path $PSScriptRoot 'Invoke-ComfyUIPowerRun.ps1') `
            -WorkflowPath $workflowPath `
            -WorkflowId 'fixture-v1' `
            -ModelLabel 'Fixture diffusion model' `
            -Quantization 'FP16' `
            -BackendLabel 'ComfyUI fixture API' `
            -SeedNodeId '3' `
            -BaseSeed 200 `
            -WorkUnits 2 `
            -GpuIndexList '0' `
            -OutputPath $mismatchPath `
            -ComfyUIBaseUri $baseUri `
            -IntervalMilliseconds 250 `
            -MinimumMeasuredSeconds 1 `
            -TimeoutSeconds 10 `
            -RequestTimeoutSeconds 5 `
            -NvidiaSmiPath $fakeNvidiaSmi
        $mismatchRaw = Get-Content -Raw -LiteralPath $mismatchPath
        $mismatchRun = $mismatchRaw | ConvertFrom-Json
        Assert-True ([string]$mismatchResult.Status -eq 'RecordedFailed' -and [string]$mismatchRun.result.status -eq 'failed') 'Output-count mismatch was not preserved as failed.'
        Assert-True ($null -eq $mismatchRun.result.throughput.workUnitsPerSecond -and $null -eq $mismatchRun.result.throughput.workUnit) 'Output-count mismatch fabricated work throughput.'
        Assert-True ($mismatchRaw -notmatch 'private-output|private workflow') 'Output-count mismatch leaked server history.'

        $failedPath = Join-Path $temporaryRoot 'failed.json'
        $failedResult = & (Join-Path $PSScriptRoot 'Invoke-ComfyUIPowerRun.ps1') `
            -WorkflowPath $workflowPath `
            -WorkflowId 'fixture-v1' `
            -ModelLabel 'Fixture diffusion model' `
            -Quantization 'FP16' `
            -BackendLabel 'ComfyUI fixture API' `
            -SeedNodeId '3' `
            -BaseSeed 300 `
            -WorkUnits 2 `
            -GpuIndexList '0' `
            -OutputPath $failedPath `
            -ComfyUIBaseUri $baseUri `
            -IntervalMilliseconds 250 `
            -MinimumMeasuredSeconds 1 `
            -TimeoutSeconds 10 `
            -RequestTimeoutSeconds 5 `
            -NvidiaSmiPath $fakeNvidiaSmi
        $failedRaw = Get-Content -Raw -LiteralPath $failedPath
        $failedRun = $failedRaw | ConvertFrom-Json
        Assert-True ([string]$failedResult.Status -eq 'RecordedFailed' -and [string]$failedRun.result.status -eq 'failed') 'Execution error was not preserved as failed.'
        Assert-True ($null -eq $failedRun.result.throughput.workUnitsPerSecond -and $failedRaw -notmatch 'private server error|private-output') 'Execution error fabricated throughput or leaked history.'

        $seeds = @(Get-Content -LiteralPath $seedLogPath)
        Assert-True (($seeds -join ',') -eq '100,101,200,201,300,301') 'Warm-up and measured seed sequence is not deterministic or cache-separating.'
    }
    finally {
        if ($null -ne $serverJob) {
            Stop-Job -Job $serverJob -ErrorAction SilentlyContinue
            Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $temporaryRoot -PathType Container) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
    }
}

Write-Host "$passed ComfyUI adapter tests passed. Only a loopback fixture server and fake telemetry were used; no image, model, or GPU hardware was accessed." -ForegroundColor Cyan
