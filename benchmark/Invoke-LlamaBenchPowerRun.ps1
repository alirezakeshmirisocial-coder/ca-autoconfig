[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$LlamaBenchPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ModelPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}$')]
    [string]$ModelLabel,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,31}$')]
    [string]$Quantization,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
    [string]$BenchmarkId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GpuIndexList,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [ValidateRange(1, 1048576)]
    [int]$PromptTokens = 512,

    [ValidateRange(1, 1048576)]
    [int]$GenerationTokens = 128,

    [ValidateRange(1, 1000)]
    [int]$BenchRepetitions = 5,

    [ValidateRange(1, 1048576)]
    [int]$BatchSize = 2048,

    [ValidateRange(1, 1048576)]
    [int]$MicroBatchSize = 512,

    [ValidateRange(1, 1024)]
    [int]$Threads = [Environment]::ProcessorCount,

    [ValidateRange(-1, 1000)]
    [int]$GpuLayers = -1,

    [ValidateSet('none', 'layer', 'row')]
    [string]$SplitMode = 'layer',

    [ValidateRange(0, 1024)]
    [int]$MainGpu = 0,

    [ValidateSet('on', 'off', 'auto')]
    [string]$FlashAttention = 'auto',

    [ValidateRange(250, 5000)]
    [int]$IntervalMilliseconds = 500,

    [ValidateRange(1, 3600)]
    [int]$MinimumMeasuredSeconds = 5,

    [ValidateRange(10, 7200)]
    [int]$TimeoutSeconds = 900,

    [ValidateRange(1, 1000)]
    [int]$Repetition = 1,

    [string]$NvidiaSmiPath = (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PowerCurve.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LlamaBenchAdapter.psm1') -Force

if (-not (Test-Path -LiteralPath $LlamaBenchPath -PathType Leaf)) { throw "llama-bench was not found: $LlamaBenchPath" }
if (-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) { throw "GGUF model was not found: $ModelPath. This adapter never downloads models." }
if (-not (Test-Path -LiteralPath $NvidiaSmiPath -PathType Leaf)) { throw "nvidia-smi was not found: $NvidiaSmiPath" }
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) { throw "Output already exists: $OutputPath. Use -Force to replace it." }
if ($MicroBatchSize -gt $BatchSize) { throw 'MicroBatchSize must not exceed BatchSize.' }

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

function ConvertTo-WindowsProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
            [void]$builder.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function New-LlamaBenchArguments {
    param([Parameter(Mandatory = $true)][int]$RunRepetitions)
    return @(
        '-m', $ModelPath,
        '-p', [string]$PromptTokens,
        '-n', [string]$GenerationTokens,
        '-r', [string]$RunRepetitions,
        '-b', [string]$BatchSize,
        '-ub', [string]$MicroBatchSize,
        '-t', [string]$Threads,
        '-ngl', [string]$GpuLayers,
        '-sm', $SplitMode,
        '-mg', [string]$MainGpu,
        '-fa', $FlashAttention,
        '-o', 'json',
        '--no-warmup'
    )
}

function Start-LlamaBenchProcess {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = [IO.Path]::GetFullPath($LlamaBenchPath)
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsProcessArgument ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'llama-bench could not be started.' }
    return $process
}

function Complete-LlamaBenchProcess {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)]$StandardOutputTask,
        [Parameter(Mandatory = $true)]$StandardErrorTask,
        [Parameter(Mandatory = $true)][Diagnostics.Stopwatch]$Clock
    )

    if (-not $Process.HasExited) {
        try { $Process.Kill() } catch { }
        $Process.WaitForExit()
        $timedOut = $true
    }
    else { $timedOut = $false }
    $Clock.Stop()
    $stdout = $StandardOutputTask.GetAwaiter().GetResult()
    [void]$StandardErrorTask.GetAwaiter().GetResult()
    $exitCode = $Process.ExitCode
    $Process.Dispose()
    return [pscustomobject]@{ TimedOut = $timedOut; ExitCode = $exitCode; StandardOutput = $stdout; Elapsed = $Clock.Elapsed }
}

function Invoke-LlamaBenchWarmup {
    $process = Start-LlamaBenchProcess -Arguments (New-LlamaBenchArguments -RunRepetitions 1)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    [void]$process.WaitForExit($TimeoutSeconds * 1000)
    $completed = Complete-LlamaBenchProcess -Process $process -StandardOutputTask $stdoutTask -StandardErrorTask $stderrTask -Clock $clock
    if ($completed.TimedOut) { throw 'llama-bench warm-up exceeded the configured timeout.' }
    if ($completed.ExitCode -ne 0) { throw "llama-bench warm-up failed with exit code $($completed.ExitCode)." }
    ConvertFrom-CALlamaBenchJson -Json $completed.StandardOutput -PromptTokens $PromptTokens -GenerationTokens $GenerationTokens -Repetitions 1 | Out-Null
    return $completed.Elapsed
}

$warmupElapsed = Invoke-LlamaBenchWarmup
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

$process = Start-LlamaBenchProcess -Arguments (New-LlamaBenchArguments -RunRepetitions $BenchRepetitions)
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$measureClock = [Diagnostics.Stopwatch]::StartNew()
$sampleIndex = 0
try {
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
        if ($process.HasExited) { break }
        $sampleIndex++
        $remaining = ($sampleIndex * $IntervalMilliseconds) - [int][Math]::Round($measureClock.Elapsed.TotalMilliseconds)
        if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
    } while (-not $process.HasExited -and $measureClock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
}
finally {
    $completed = Complete-LlamaBenchProcess -Process $process -StandardOutputTask $stdoutTask -StandardErrorTask $stderrTask -Clock $measureClock
}

$resultStatus = 'passed'
$resultError = $null
$promptTokensPerSecond = $null
$generationTokensPerSecond = $null
$backend = 'llama.cpp unknown build'
if ($completed.TimedOut) {
    $resultStatus = 'failed'
    $resultError = 'The measured llama-bench process exceeded the configured timeout.'
}
elseif ($completed.ExitCode -ne 0) {
    $resultStatus = 'failed'
    $resultError = 'The measured llama-bench process failed; console output was intentionally omitted from the export.'
}
else {
    try {
        $metrics = ConvertFrom-CALlamaBenchJson -Json $completed.StandardOutput -PromptTokens $PromptTokens -GenerationTokens $GenerationTokens -Repetitions $BenchRepetitions
        $promptTokensPerSecond = $metrics.PromptTokensPerSecond
        $generationTokensPerSecond = $metrics.GenerationTokensPerSecond
        $backend = $metrics.Backend
    }
    catch {
        $resultStatus = 'failed'
        $resultError = 'The measured llama-bench process did not return valid, exact pp/tg evidence.'
    }
}
if ($resultStatus -eq 'passed' -and $completed.Elapsed.TotalSeconds -lt $MinimumMeasuredSeconds) {
    $resultStatus = 'incomplete'
    $resultError = 'The measured process ended before the configured minimum window; increase token counts or repetitions.'
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
    schemaVersion = 1
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
        class        = 'llama.cpp'
        name         = "$BenchmarkId · llama-bench pp$PromptTokens/tg$GenerationTokens · r=$BenchRepetitions · b=$BatchSize · ub=$MicroBatchSize · t=$Threads · ngl=$GpuLayers · split=$SplitMode · main_gpu=$MainGpu · fa=$FlashAttention · process-window"
        model        = $ModelLabel
        quantization = $Quantization
        backend      = $backend
    }
    protocol      = [pscustomobject][ordered]@{
        warmupSeconds        = [int][Math]::Ceiling($warmupElapsed.TotalSeconds)
        sampleSeconds        = [int][Math]::Max(1, [Math]::Ceiling($completed.Elapsed.TotalSeconds))
        intervalMilliseconds = $IntervalMilliseconds
        repetition           = $Repetition
    }
    result        = [pscustomobject][ordered]@{
        status     = $resultStatus
        throughput = [pscustomobject][ordered]@{
            promptTokensPerSecond     = $promptTokensPerSecond
            generationTokensPerSecond = $generationTokensPerSecond
        }
        error      = $resultError
    }
    gpus          = @($gpus)
}

Assert-CAPowerCurveRun -Run $run | Out-Null
$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $fullOutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }
$run | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $fullOutputPath -Encoding UTF8

[pscustomobject]@{
    Status                    = if ($resultStatus -eq 'passed') { 'Recorded' } elseif ($resultStatus -eq 'incomplete') { 'RecordedIncomplete' } else { 'RecordedFailed' }
    Output                    = $fullOutputPath
    RunId                     = $run.runId
    Model                     = $ModelLabel
    Quantization              = $Quantization
    PromptTokensPerSecond     = $promptTokensPerSecond
    GenerationTokensPerSecond = $generationTokensPerSecond
    MeasuredSeconds           = [Math]::Round($completed.Elapsed.TotalSeconds, 3)
    SamplesPerGpu             = @($gpus[0].samples).Count
    HardwareWrites            = $false
    ContainsPaths             = $false
    ContainsRawCommand        = $false
}
