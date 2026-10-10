[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LlamaBenchAdapter.psm1') -Force

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

function New-FixtureJson {
    param(
        [int]$PromptTokens = 512,
        [int]$GenerationTokens = 128,
        [int]$Repetitions = 3,
        [double]$PromptRate = 100.0,
        [double]$GenerationRate = 25.0,
        [string]$Commit = 'fixture1',
        [string]$Backends = 'CUDA'
    )
    $samplesPrompt = @(for ($i = 0; $i -lt $Repetitions; $i++) { $PromptRate })
    $samplesGeneration = @(for ($i = 0; $i -lt $Repetitions; $i++) { $GenerationRate })
    @(
        [ordered]@{
            build_commit = $Commit; backends = $Backends; model_filename = 'C:\Users\Private\secret.gguf'
            cpu_info = 'Private CPU'; gpu_info = 'Private GPU'; n_prompt = $PromptTokens; n_gen = 0
            avg_ts = $PromptRate; samples_ts = $samplesPrompt
        },
        [ordered]@{
            build_commit = $Commit; backends = $Backends; model_filename = 'C:\Users\Private\secret.gguf'
            cpu_info = 'Private CPU'; gpu_info = 'Private GPU'; n_prompt = 0; n_gen = $GenerationTokens
            avg_ts = $GenerationRate; samples_ts = $samplesGeneration
        }
    ) | ConvertTo-Json -Depth 5 -Compress
}

Test-Case 'official pp and tg rows produce exact throughput and a safe backend label' {
    $metrics = ConvertFrom-CALlamaBenchJson -Json (New-FixtureJson) -PromptTokens 512 -GenerationTokens 128 -Repetitions 3
    Assert-True ([double]$metrics.PromptTokensPerSecond -eq 100.0) 'Prompt-processing throughput is wrong.'
    Assert-True ([double]$metrics.GenerationTokensPerSecond -eq 25.0) 'Generation throughput is wrong.'
    Assert-True ([string]$metrics.Backend -eq 'llama.cpp fixture1 · CUDA') 'Backend fingerprint is wrong.'
    Assert-True ((($metrics | ConvertTo-Json -Compress) -notmatch 'Private|secret|model_filename|cpu_info|gpu_info')) 'Sensitive source fields escaped the parser.'
}

Test-Case 'mismatched requested token counts fail closed' {
    Assert-Throws {
        ConvertFrom-CALlamaBenchJson -Json (New-FixtureJson) -PromptTokens 1024 -GenerationTokens 128 -Repetitions 3
    } 'exact requested pp and tg' 'A mismatched prompt row was accepted.'
}

Test-Case 'extra result rows fail closed' {
    $document = @((New-FixtureJson | ConvertFrom-Json))
    $document += $document[0]
    Assert-Throws {
        ConvertFrom-CALlamaBenchJson -Json ($document | ConvertTo-Json -Depth 5 -Compress) -PromptTokens 512 -GenerationTokens 128 -Repetitions 3
    } 'exactly one prompt-processing row' 'An ambiguous multi-row result was accepted.'
}

Test-Case 'sample count must match declared repetitions' {
    Assert-Throws {
        ConvertFrom-CALlamaBenchJson -Json (New-FixtureJson -Repetitions 2) -PromptTokens 512 -GenerationTokens 128 -Repetitions 3
    } 'expected 3' 'A partial repetition set was accepted.'
}

Test-Case 'zero throughput fails closed' {
    Assert-Throws {
        ConvertFrom-CALlamaBenchJson -Json (New-FixtureJson -PromptRate 0) -PromptTokens 512 -GenerationTokens 128 -Repetitions 3
    } 'positive finite' 'Zero throughput was accepted.'
}

Test-Case 'inconsistent build identity fails closed' {
    $document = @((New-FixtureJson | ConvertFrom-Json))
    $document[1].build_commit = 'other-build'
    Assert-Throws {
        ConvertFrom-CALlamaBenchJson -Json ($document | ConvertTo-Json -Depth 5 -Compress) -PromptTokens 512 -GenerationTokens 128 -Repetitions 3
    } 'build identity' 'Inconsistent build identities were accepted.'
}

Test-Case 'live adapter remains local-only, query-only, and privacy-safe' {
    $source = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Invoke-LlamaBenchPowerRun.ps1')
    Assert-True ($source -match 'This adapter never downloads models') 'The no-download boundary is missing.'
    Assert-True ($source -match "'-o', 'json'" -and $source -match "'--no-warmup'") 'The official deterministic JSON protocol is missing.'
    Assert-True ($source -match '--query-gpu=' -and $source -notmatch '(?i)[''"]-(pl|lgc|rgc|ac)[''"]') 'Adapter contains a GPU mutation path.'
    Assert-True ($source -notmatch 'Start-ScheduledTask|Register-ScheduledTask|Verb\s+RunAs|Invoke-WebRequest|Invoke-RestMethod|HttpClient') 'Adapter contains elevation, task, or network control.'
    Assert-True ($source -match 'ContainsPaths\s+=\s+\$false' -and $source -match 'ContainsRawCommand\s+=\s+\$false') 'Adapter does not explicitly report path/command omission.'
}

Test-Case 'missing model is rejected before creating output' {
    $temporaryOutput = Join-Path ([IO.Path]::GetTempPath()) ('ca-llama-missing-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Invoke-LlamaBenchPowerRun.ps1') `
                -LlamaBenchPath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) `
                -ModelPath (Join-Path ([IO.Path]::GetTempPath()) 'missing-ca-model.gguf') `
                -ModelLabel 'Missing model' `
                -Quantization 'Q4_K_M' `
                -BenchmarkId 'missing-model-v1' `
                -GpuIndexList '0' `
                -OutputPath $temporaryOutput
        } 'never downloads models' 'A missing model did not fail with the local-only guidance.'
        Assert-True (-not (Test-Path -LiteralPath $temporaryOutput)) 'A missing-model failure created an export.'
    }
    finally { Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue }
}

Test-Case 'local process fixture samples concurrently and strips private source fields' {
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('ca-llama-adapter-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    try {
        $benchExe = Join-Path $temporaryRoot 'fake-llama-bench.exe'
        $modelPath = Join-Path $temporaryRoot 'private model.gguf'
        $nvidiaPath = Join-Path $temporaryRoot 'fake-nvidia-smi.cmd'
        $outputPath = Join-Path $temporaryRoot 'passed.json'
        $failedPath = Join-Path $temporaryRoot 'failed.json'
        $fastFailedPath = Join-Path $temporaryRoot 'fast-failed.json'
        Set-Content -LiteralPath $modelPath -Value 'fixture' -Encoding ASCII
        Set-Content -LiteralPath $nvidiaPath -Value @'
@echo off
echo 0, Fixture GPU, 999.1, 280, 120, 52, 88, 1000, 24000, 1600
'@ -Encoding ASCII

        $fixtureSource = @'
using System;
using System.Linq;
using System.Threading;

public static class FakeLlamaBench {
    private static string Get(string[] args, string name) {
        int index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : "";
    }
    private static string Samples(int count, string value) {
        return string.Join(",", Enumerable.Repeat(value, count));
    }
    public static int Main(string[] args) {
        int repetitions = int.Parse(Get(args, "-r"));
        int prompt = int.Parse(Get(args, "-p"));
        int generation = int.Parse(Get(args, "-n"));
        bool measured = repetitions > 1;
        string fail = Environment.GetEnvironmentVariable("CA_LLAMA_BENCH_FIXTURE_FAIL");
        if (measured && fail == "2") {
            Console.Error.WriteLine("private immediate failure C:\\Users\\Private\\secret.gguf");
            return 8;
        }
        Thread.Sleep(measured ? 1250 : 120);
        if (measured && fail == "1") {
            Console.Error.WriteLine("private failure C:\\Users\\Private\\secret.gguf");
            return 7;
        }
        string common = "\"build_commit\":\"fixture1\",\"backends\":\"CUDA\",\"model_filename\":\"C:\\\\Users\\\\Private\\\\secret.gguf\",\"cpu_info\":\"Private CPU\",\"gpu_info\":\"Private GPU\"";
        string pp = "{" + common + ",\"n_prompt\":" + prompt + ",\"n_gen\":0,\"avg_ts\":100.0,\"samples_ts\":[" + Samples(repetitions, "100.0") + "]}";
        string tg = "{" + common + ",\"n_prompt\":0,\"n_gen\":" + generation + ",\"avg_ts\":25.0,\"samples_ts\":[" + Samples(repetitions, "25.0") + "]}";
        Console.Write("[" + pp + "," + tg + "]");
        return 0;
    }
}
'@
        $fixtureSourcePath = Join-Path $temporaryRoot 'FakeLlamaBench.cs'
        Set-Content -LiteralPath $fixtureSourcePath -Value $fixtureSource -Encoding UTF8
        $compilerPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) {
            $compilerPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
        }
        Assert-True (Test-Path -LiteralPath $compilerPath -PathType Leaf) '.NET Framework C# compiler is unavailable for the local process fixture.'
        & $compilerPath /nologo /target:exe "/out:$benchExe" $fixtureSourcePath
        Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $benchExe -PathType Leaf)) 'Could not compile the local llama-bench fixture.'

        $result = & (Join-Path $PSScriptRoot 'Invoke-LlamaBenchPowerRun.ps1') `
            -LlamaBenchPath $benchExe `
            -ModelPath $modelPath `
            -ModelLabel 'Fixture 7B' `
            -Quantization 'Q4_K_M' `
            -BenchmarkId 'fixture-v1' `
            -GpuIndexList '0' `
            -OutputPath $outputPath `
            -PromptTokens 512 `
            -GenerationTokens 128 `
            -BenchRepetitions 3 `
            -IntervalMilliseconds 250 `
            -MinimumMeasuredSeconds 1 `
            -TimeoutSeconds 30 `
            -NvidiaSmiPath $nvidiaPath
        $raw = Get-Content -Raw -LiteralPath $outputPath
        $run = $raw | ConvertFrom-Json
        Assert-True ([string]$result.Status -eq 'Recorded' -and [string]$run.result.status -eq 'passed') 'Valid fixture run was not recorded as passed.'
        Assert-True ([int]$run.schemaVersion -eq 3 -and [string]$run.measurement.powerWindow -eq 'process-window') 'llama-bench output lost process-window power provenance.'
        Assert-True ([DateTime]$run.measurement.endedUtc -gt [DateTime]$run.measurement.startedUtc) 'llama-bench output lost its explicit measurement window.'
        Assert-True ([string]$run.measurement.promptRateWindow -eq 'prompt-phase' -and [string]$run.measurement.generationRateWindow -eq 'generation-phase') 'llama-bench output mislabeled phase-specific throughput.'
        Assert-True ([double]$run.result.throughput.promptTokensPerSecond -eq 100.0 -and [double]$run.result.throughput.generationTokensPerSecond -eq 25.0) 'Fixture throughput changed.'
        Assert-True (@($run.gpus[0].samples).Count -ge 4) 'GPU telemetry was not sampled concurrently.'
        Assert-True ($raw -notmatch 'Users\\\\Private|secret\.gguf|Private CPU|Private GPU|model_filename|cpu_info|gpu_info') 'Private llama-bench fields escaped into the export.'
        Assert-True ([string]$run.workload.backend -eq 'llama.cpp fixture1 · CUDA') 'Safe build/backend fingerprint was not exported.'

        $env:CA_LLAMA_BENCH_FIXTURE_FAIL = '1'
        $failedResult = & (Join-Path $PSScriptRoot 'Invoke-LlamaBenchPowerRun.ps1') `
            -LlamaBenchPath $benchExe `
            -ModelPath $modelPath `
            -ModelLabel 'Fixture 7B' `
            -Quantization 'Q4_K_M' `
            -BenchmarkId 'fixture-v1' `
            -GpuIndexList '0' `
            -OutputPath $failedPath `
            -BenchRepetitions 3 `
            -IntervalMilliseconds 250 `
            -MinimumMeasuredSeconds 1 `
            -TimeoutSeconds 30 `
            -NvidiaSmiPath $nvidiaPath
        $failedRaw = Get-Content -Raw -LiteralPath $failedPath
        $failedRun = $failedRaw | ConvertFrom-Json
        Assert-True ([string]$failedResult.Status -eq 'RecordedFailed' -and [string]$failedRun.result.status -eq 'failed') 'Failed child process was not preserved as failed evidence.'
        Assert-True ($null -eq $failedRun.result.throughput.promptTokensPerSecond -and $null -eq $failedRun.result.throughput.generationTokensPerSecond) 'Failed process retained invented throughput.'
        Assert-True ($null -eq $failedRun.measurement.promptRateWindow -and $null -eq $failedRun.measurement.generationRateWindow) 'Failed process retained a nonexistent throughput window.'
        Assert-True ($failedRaw -notmatch 'Users\\\\Private|secret\.gguf|private failure') 'Child stderr or model path leaked into failed export.'

        $env:CA_LLAMA_BENCH_FIXTURE_FAIL = '2'
        $fastFailedResult = & (Join-Path $PSScriptRoot 'Invoke-LlamaBenchPowerRun.ps1') `
            -LlamaBenchPath $benchExe `
            -ModelPath $modelPath `
            -ModelLabel 'Fixture 7B' `
            -Quantization 'Q4_K_M' `
            -BenchmarkId 'fixture-v1' `
            -GpuIndexList '0' `
            -OutputPath $fastFailedPath `
            -BenchRepetitions 3 `
            -IntervalMilliseconds 250 `
            -MinimumMeasuredSeconds 1 `
            -TimeoutSeconds 30 `
            -NvidiaSmiPath $nvidiaPath
        $fastFailedRun = Get-Content -Raw -LiteralPath $fastFailedPath | ConvertFrom-Json
        Assert-True ([string]$fastFailedResult.Status -eq 'RecordedFailed' -and @($fastFailedRun.gpus[0].samples).Count -eq 1) 'Immediate child failure was not preserved with one explicit telemetry sample.'
    }
    finally {
        Remove-Item Env:\CA_LLAMA_BENCH_FIXTURE_FAIL -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "$passed llama-bench adapter tests passed. Only local process fixtures were used; no model, network service, or GPU hardware was accessed." -ForegroundColor Cyan
