[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('llama.cpp', 'ollama', 'comfyui', 'other')]
    [string]$WorkloadClass,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkloadName,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Model,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Quantization,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Backend,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GpuIndexList,

    [AllowNull()]
    [Nullable[double]]$PromptTokensPerSecond,

    [AllowNull()]
    [Nullable[double]]$GenerationTokensPerSecond,

    [ValidateSet('passed', 'failed', 'incomplete')]
    [string]$ResultStatus = 'passed',

    [AllowEmptyString()]
    [string]$ErrorMessage = '',

    [ValidateRange(0, 3600)]
    [int]$WarmupSeconds = 30,

    [ValidateRange(1, 86400)]
    [int]$SampleSeconds = 60,

    [ValidateRange(250, 60000)]
    [int]$IntervalMilliseconds = 1000,

    [ValidateRange(1, 1000)]
    [int]$Repetition = 1,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [string]$NvidiaSmiPath = (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PowerCurve.psm1') -Force

if (-not (Test-Path -LiteralPath $NvidiaSmiPath -PathType Leaf)) {
    throw "nvidia-smi was not found: $NvidiaSmiPath"
}
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "Output already exists: $OutputPath. Use -Force to replace it."
}
if ($ResultStatus -eq 'passed' -and $null -eq $PromptTokensPerSecond -and $null -eq $GenerationTokensPerSecond) {
    throw 'A passed run requires -PromptTokensPerSecond or -GenerationTokensPerSecond.'
}

$gpuIndexes = @()
foreach ($token in @($GpuIndexList -split ',')) {
    $index = 0
    if ([string]::IsNullOrWhiteSpace($token) -or -not [int]::TryParse($token.Trim(), [ref]$index) -or $index -lt 0) {
        throw "Invalid GPU index list '$GpuIndexList'. Use a comma-separated list such as 0,1."
    }
    $gpuIndexes += $index
}
if (@($gpuIndexes | Select-Object -Unique).Count -ne $gpuIndexes.Count) {
    throw 'GPU indices must not contain duplicates.'
}

function ConvertTo-NullableDouble {
    param($Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or $text -match '^(N/A|\[N/A\]|Not Supported)$') { return $null }
    $number = 0.0
    if (-not [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $null
    }
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
    finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($exitCode -ne 0) { throw "nvidia-smi telemetry query for GPU $Index failed with exit code ${exitCode}: $output" }
    $rows = @($output | ConvertFrom-Csv -Header @('Index', 'Name', 'Driver', 'PowerLimit', 'PowerDraw', 'Temperature', 'Utilization', 'MemoryUsed', 'MemoryTotal', 'Clock'))
    if ($rows.Count -ne 1 -or [int]$rows[0].Index -ne $Index) {
        throw "Unexpected nvidia-smi response for GPU ${Index}: $output"
    }
    return $rows[0]
}

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

if ($WarmupSeconds -gt 0) {
    Write-Host "Warm-up: keep '$WorkloadName' running for $WarmupSeconds seconds." -ForegroundColor Cyan
    Start-Sleep -Seconds $WarmupSeconds
}

$sampleTarget = [Math]::Max(1, [int][Math]::Ceiling(($SampleSeconds * 1000.0) / $IntervalMilliseconds))
$measurementStartedUtc = [DateTime]::UtcNow
$clock = [Diagnostics.Stopwatch]::StartNew()
for ($sampleIndex = 0; $sampleIndex -lt $sampleTarget; $sampleIndex++) {
    foreach ($index in $gpuIndexes) {
        $row = Read-GpuTelemetry -Index $index
        $gpuData[[string]$index].samples.Add([pscustomobject][ordered]@{
            elapsedMilliseconds = [int][Math]::Round($clock.Elapsed.TotalMilliseconds)
            powerDrawWatts      = ConvertTo-NullableDouble $row.PowerDraw
            temperatureC        = ConvertTo-NullableDouble $row.Temperature
            utilizationPercent  = ConvertTo-NullableDouble $row.Utilization
            memoryUsedMiB       = ConvertTo-NullableDouble $row.MemoryUsed
            memoryTotalMiB      = ConvertTo-NullableDouble $row.MemoryTotal
            graphicsClockMHz    = ConvertTo-NullableDouble $row.Clock
        })
    }
    $nextTarget = ($sampleIndex + 1) * $IntervalMilliseconds
    $remaining = $nextTarget - [int][Math]::Round($clock.Elapsed.TotalMilliseconds)
    if ($sampleIndex -lt $sampleTarget - 1 -and $remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
}
$clock.Stop()
$measurementEndedUtc = [DateTime]::UtcNow

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
        class        = $WorkloadClass
        name         = $WorkloadName
        model        = $Model
        quantization = $Quantization
        backend      = $Backend
    }
    protocol      = [pscustomobject][ordered]@{
        warmupSeconds       = $WarmupSeconds
        sampleSeconds       = $SampleSeconds
        intervalMilliseconds = $IntervalMilliseconds
        repetition          = $Repetition
    }
    measurement   = [pscustomobject][ordered]@{
        powerWindow         = 'steady-state'
        promptRateWindow    = if ($null -eq $PromptTokensPerSecond) { $null } else { 'steady-state' }
        generationRateWindow = if ($null -eq $GenerationTokensPerSecond) { $null } else { 'steady-state' }
        workRateWindow      = $null
        startedUtc          = $measurementStartedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        endedUtc            = $measurementEndedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    result        = [pscustomobject][ordered]@{
        status     = $ResultStatus
        throughput = [pscustomobject][ordered]@{
            promptTokensPerSecond     = if ($null -eq $PromptTokensPerSecond) { $null } else { [double]$PromptTokensPerSecond }
            generationTokensPerSecond = if ($null -eq $GenerationTokensPerSecond) { $null } else { [double]$GenerationTokensPerSecond }
            workUnitsPerSecond        = $null
            workUnit                  = $null
        }
        error      = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage }
    }
    gpus          = @($gpus)
}

Assert-CAPowerCurveRun -Run $run | Out-Null
$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $fullOutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}
$run | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $fullOutputPath -Encoding UTF8

[pscustomobject]@{
    Status = 'Recorded'
    Output = $fullOutputPath
    RunId = $run.runId
    Gpus = $gpus.Count
    SamplesPerGpu = $sampleTarget
    HardwareWrites = $false
    ContainsMachineIdentifiers = $false
}
