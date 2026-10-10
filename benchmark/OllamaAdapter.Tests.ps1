[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OllamaAdapter.psm1') -Force

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

Test-Case 'official Ollama counters convert nanoseconds to throughput' {
    $metrics = ConvertFrom-CAOllamaGenerateResponse ([pscustomobject]@{
        done = $true; prompt_eval_count = 100; prompt_eval_cached_count = 20; prompt_eval_duration = 2000000000
        eval_count = 50; eval_duration = 2500000000
    })
    Assert-True ([Math]::Abs([double]$metrics.PromptTokensPerSecond - 40.0) -lt 0.000001) 'Uncached prompt throughput is wrong.'
    Assert-True ([Math]::Abs([double]$metrics.GenerationTokensPerSecond - 20.0) -lt 0.000001) 'Generation throughput is wrong.'
}

Test-Case 'missing cached count treats all prompt tokens as evaluated' {
    $metrics = ConvertFrom-CAOllamaGenerateResponse ([pscustomobject]@{
        done = $true; prompt_eval_count = 60; prompt_eval_duration = 1000000000
        eval_count = 10; eval_duration = 1000000000
    })
    Assert-True ([double]$metrics.PromptTokensPerSecond -eq 60.0) 'Prompt throughput should use all tokens when no cached count is reported.'
}

Test-Case 'fully cached prompt retains generation throughput without inventing prompt speed' {
    $metrics = ConvertFrom-CAOllamaGenerateResponse ([pscustomobject]@{
        done = $true; prompt_eval_count = 50; prompt_eval_cached_count = 50; prompt_eval_duration = 0
        eval_count = 25; eval_duration = 1000000000
    })
    Assert-True ($null -eq $metrics.PromptTokensPerSecond) 'A fully cached prompt produced an uncached prompt speed.'
    Assert-True ([double]$metrics.GenerationTokensPerSecond -eq 25.0) 'Generation speed was lost.'
}

Test-Case 'incomplete response fails closed' {
    Assert-Throws { ConvertFrom-CAOllamaGenerateResponse ([pscustomobject]@{
        done = $false; prompt_eval_count = 10; prompt_eval_duration = 1; eval_count = 10; eval_duration = 1
    }) } 'done=true' 'An incomplete response was accepted.'
}

Test-Case 'impossible cache accounting fails closed' {
    Assert-Throws { ConvertFrom-CAOllamaGenerateResponse ([pscustomobject]@{
        done = $true; prompt_eval_count = 10; prompt_eval_cached_count = 11; prompt_eval_duration = 1
        eval_count = 10; eval_duration = 1
    }) } 'cached prompt count exceeds' 'Impossible cache accounting was accepted.'
}

Test-Case 'positive token count requires a positive duration' {
    Assert-Throws { ConvertFrom-CAOllamaGenerateResponse ([pscustomobject]@{
        done = $true; prompt_eval_count = 10; prompt_eval_duration = 0; eval_count = 0; eval_duration = 0
    }) } 'without prompt_eval_duration' 'Positive token count with zero duration was accepted.'
}

Test-Case 'live adapter remains local-first, privacy-safe, and free of GPU mutation flags' {
    $source = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Invoke-OllamaPowerRun.ps1')
    Assert-True ($source -match 'IPAddress\]::IsLoopback' -and $source -match 'AllowRemoteEndpoint') 'Remote endpoint safety gate is missing.'
    Assert-True ($source -match 'AllowAutoRedirect\s*=\s*\$false') 'Loopback prompt requests may follow a redirect to another host.'
    Assert-True ($source -match '/api/generate' -and $source -match 'PostAsync') 'Measured Ollama request path is missing.'
    Assert-True ($source -match 'this adapter never pulls models') 'Missing-model guidance does not preserve the no-pull boundary.'
    Assert-True ($source -match '--query-gpu=' -and $source -notmatch '(?i)[''"]-(pl|lgc|rgc|ac)[''"]') 'Adapter contains a GPU mutation path.'
    Assert-True ($source -notmatch 'Start-ScheduledTask|Register-ScheduledTask|Verb\s+RunAs') 'Adapter contains elevation or scheduled-task control.'
    Assert-True ($source -match 'ContainsPromptOrResponse\s+=\s+\$false') 'Adapter does not explicitly report prompt/response omission.'
}

Test-Case 'non-loopback endpoint is rejected before prompt or hardware access' {
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-OllamaPowerRun.ps1') `
            -Model 'fixture-model' `
            -Prompt 'must not leave this process' `
            -BenchmarkId 'remote-rejection' `
            -GpuIndexList '0' `
            -OutputPath (Join-Path $env:TEMP 'ca-remote-rejection-must-not-exist.json') `
            -OllamaBaseUri 'http://192.0.2.1:11434' `
            -NvidiaSmiPath 'missing-nvidia-smi.exe'
    } 'not loopback' 'A remote endpoint was not rejected before workload or GPU access.'
}

Test-Case 'local mock server records a complete privacy-safe run while telemetry is sampled' {
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('ca-ollama-adapter-' + [Guid]::NewGuid().ToString('N'))
    $listenerProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listenerProbe.Start()
    $port = ([Net.IPEndPoint]$listenerProbe.LocalEndpoint).Port
    $listenerProbe.Stop()
    $serverJob = $null
    try {
        New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
        $fakeNvidiaSmi = Join-Path $temporaryRoot 'nvidia-smi.cmd'
        Set-Content -LiteralPath $fakeNvidiaSmi -Encoding Ascii -Value @(
            '@echo off',
            'echo 0, NVIDIA GeForce RTX TEST, 999.0, 250.00, 200.00, 55, 90, 10000, 24000, 1500',
            'exit /b 0'
        )
        $serverJob = Start-Job -ArgumentList $port -ScriptBlock {
            param($Port)
            $listener = [Net.HttpListener]::new()
            $listener.Prefixes.Add("http://127.0.0.1:$Port/")
            $listener.Start()
            $generationCount = 0
            try {
                while ($generationCount -lt 4) {
                    $context = $listener.GetContext()
                    $path = $context.Request.Url.AbsolutePath
                    if ($path -eq '/api/version') {
                        $responseText = '{"version":"0.0-fixture"}'
                    }
                    elseif ($path -eq '/api/show') {
                        $responseText = '{"details":{"quantization_level":"Q4_K_M"}}'
                    }
                    elseif ($path -eq '/api/generate') {
                        $generationCount++
                        if ($generationCount -in @(1, 3)) {
                            $responseText = '{"done":true}'
                        }
                        elseif ($generationCount -eq 2) {
                            Start-Sleep -Milliseconds 1200
                            $responseText = '{"done":true,"prompt_eval_count":100,"prompt_eval_cached_count":20,"prompt_eval_duration":2000000000,"eval_count":50,"eval_duration":2500000000,"response":"never export this response"}'
                        }
                        else {
                            Start-Sleep -Milliseconds 600
                            $context.Response.StatusCode = 500
                            $responseText = '{"error":"private server detail must not be exported"}'
                        }
                    }
                    else {
                        $context.Response.StatusCode = 404
                        $responseText = '{"error":"not found"}'
                    }
                    $bytes = [Text.Encoding]::UTF8.GetBytes($responseText)
                    $context.Response.ContentType = 'application/json'
                    $context.Response.ContentLength64 = $bytes.Length
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $context.Response.OutputStream.Close()
                }
            }
            finally { $listener.Stop() }
        }

        $baseUri = "http://127.0.0.1:$port"
        $ready = $false
        for ($attempt = 0; $attempt -lt 40 -and -not $ready; $attempt++) {
            try {
                $null = Invoke-WebRequest -UseBasicParsing -Uri "$baseUri/api/version" -TimeoutSec 1
                $ready = $true
            }
            catch {
                if ($serverJob.State -in @('Failed', 'Stopped', 'Completed')) { break }
                Start-Sleep -Milliseconds 100
            }
        }
        Assert-True $ready 'Local Ollama fixture server did not become ready.'

        $outputPath = Join-Path $temporaryRoot 'run.json'
        $result = & (Join-Path $PSScriptRoot 'Invoke-OllamaPowerRun.ps1') `
            -Model 'fixture-model' `
            -Prompt 'private benchmark prompt' `
            -BenchmarkId 'fixture-v1' `
            -GpuIndexList '0' `
            -OutputPath $outputPath `
            -OllamaBaseUri $baseUri `
            -NumPredict 64 `
            -WarmupNumPredict 2 `
            -IntervalMilliseconds 250 `
            -MinimumMeasuredSeconds 1 `
            -TimeoutSeconds 10
        Assert-True ([string]$result.Status -eq 'Recorded') 'Fixture-backed adapter did not record a passed run.'
        Assert-True (-not [bool]$result.HardwareWrites -and -not [bool]$result.ContainsPromptOrResponse) 'Adapter result reported a privacy or hardware-write violation.'

        $rawRun = Get-Content -Raw -LiteralPath $outputPath
        Assert-True ($rawRun -notmatch 'private benchmark prompt|never export this response') 'Prompt or generated response leaked into the export.'
        $run = $rawRun | ConvertFrom-Json
        Assert-True ([string]$run.workload.quantization -eq 'Q4_K_M') 'Model quantization was not captured from /api/show.'
        Assert-True ([string]$run.workload.name -match '^fixture-v1 .+num_ctx=4096 .+num_predict=64') 'Non-sensitive benchmark fingerprint is incomplete.'
        Assert-True ([Math]::Abs([double]$run.result.throughput.promptTokensPerSecond - 40.0) -lt 0.000001) 'Integrated prompt throughput is wrong.'
        Assert-True ([Math]::Abs([double]$run.result.throughput.generationTokensPerSecond - 20.0) -lt 0.000001) 'Integrated generation throughput is wrong.'
        Assert-True (@($run.gpus[0].samples).Count -ge 4) 'Measured request did not collect concurrent GPU samples.'

        $failedOutputPath = Join-Path $temporaryRoot 'failed-run.json'
        $failedResult = & (Join-Path $PSScriptRoot 'Invoke-OllamaPowerRun.ps1') `
            -Model 'fixture-model' `
            -Prompt 'another private prompt' `
            -BenchmarkId 'fixture-v1' `
            -GpuIndexList '0' `
            -OutputPath $failedOutputPath `
            -OllamaBaseUri $baseUri `
            -NumPredict 64 `
            -WarmupNumPredict 2 `
            -IntervalMilliseconds 250 `
            -MinimumMeasuredSeconds 1 `
            -TimeoutSeconds 10
        Assert-True ([string]$failedResult.Status -eq 'RecordedFailed') 'A failed measured request was not preserved as a failed run.'
        $rawFailedRun = Get-Content -Raw -LiteralPath $failedOutputPath
        Assert-True ($rawFailedRun -notmatch 'another private prompt|private server detail') 'A failed request leaked prompt or server response text.'
        $failedRun = $rawFailedRun | ConvertFrom-Json
        Assert-True ([string]$failedRun.result.status -eq 'failed') 'Failed request export has the wrong status.'
        Assert-True ($null -eq $failedRun.result.throughput.promptTokensPerSecond -and $null -eq $failedRun.result.throughput.generationTokensPerSecond) 'Failed request fabricated throughput.'
    }
    finally {
        if ($null -ne $serverJob) {
            Stop-Job -Job $serverJob -ErrorAction SilentlyContinue
            Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $temporaryRoot -PathType Container) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
    }
}

Write-Host "$passed Ollama adapter tests passed. Only a local fixture server was contacted; no external service or GPU hardware was used." -ForegroundColor Cyan
