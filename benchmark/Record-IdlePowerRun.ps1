[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('baseline', 'candidate')]
    [string]$Condition,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._+/-]{0,79}$')]
    [string]$ProfileLabel,

    [Parameter(Mandatory = $true)]
    [ValidateSet('vendor-auto', 'persistent-graphics-lock', 'unknown')]
    [string]$ClockPolicy,

    [AllowNull()]
    [Nullable[double]]$GraphicsClockMaximumMHz,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GpuIndexList,

    [ValidateRange(0, 3600)]
    [int]$SettleSeconds = 30,

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
Import-Module (Join-Path $PSScriptRoot 'IdlePower.psm1') -Force

if (-not (Test-Path -LiteralPath $NvidiaSmiPath -PathType Leaf)) {
    throw "nvidia-smi was not found: $NvidiaSmiPath"
}
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "Output already exists: $OutputPath. Use -Force to replace it."
}
if ($ClockPolicy -eq 'persistent-graphics-lock' -and $null -eq $GraphicsClockMaximumMHz) {
    throw '-GraphicsClockMaximumMHz is required for a persistent graphics-clock lock.'
}
if ($null -ne $GraphicsClockMaximumMHz -and [double]$GraphicsClockMaximumMHz -le 0) {
    throw '-GraphicsClockMaximumMHz must be positive when supplied.'
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

function ConvertTo-NullableIdleDouble {
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

function Read-IdleGpuTelemetry {
    param([Parameter(Mandatory = $true)][int]$Index)

    $arguments = @(
        '-i', [string]$Index,
        '--query-gpu=index,name,driver_version,power.limit,power.draw,temperature.gpu,utilization.gpu,clocks.gr',
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
    $rows = @($output | ConvertFrom-Csv -Header @('Index', 'Name', 'Driver', 'PowerLimit', 'PowerDraw', 'Temperature', 'Utilization', 'Clock'))
    if ($rows.Count -ne 1 -or [int]$rows[0].Index -ne $Index) {
        throw "Unexpected nvidia-smi response for GPU ${Index}: $output"
    }
    return $rows[0]
}

$gpuData = [ordered]@{}
foreach ($index in $gpuIndexes) {
    $inventory = Read-IdleGpuTelemetry -Index $index
    $gpuData[[string]$index] = [ordered]@{
        index           = $index
        model           = ([string]$inventory.Name).Trim()
        driver          = ([string]$inventory.Driver).Trim()
        powerLimitWatts = ConvertTo-NullableIdleDouble $inventory.PowerLimit
        samples         = New-Object Collections.Generic.List[object]
    }
}

if ($SettleSeconds -gt 0) {
    Write-Host "Idle settling window: close GPU workloads and leave the desktop untouched for $SettleSeconds seconds." -ForegroundColor Cyan
    Start-Sleep -Seconds $SettleSeconds
}

$sampleTarget = [Math]::Max(1, [int][Math]::Ceiling(($SampleSeconds * 1000.0) / $IntervalMilliseconds))
$clock = [Diagnostics.Stopwatch]::StartNew()
for ($sampleIndex = 0; $sampleIndex -lt $sampleTarget; $sampleIndex++) {
    foreach ($index in $gpuIndexes) {
        $row = Read-IdleGpuTelemetry -Index $index
        $gpuData[[string]$index].samples.Add([pscustomobject][ordered]@{
            elapsedMilliseconds = [int][Math]::Round($clock.Elapsed.TotalMilliseconds)
            powerDrawWatts      = ConvertTo-NullableIdleDouble $row.PowerDraw
            temperatureC        = ConvertTo-NullableIdleDouble $row.Temperature
            utilizationPercent  = ConvertTo-NullableIdleDouble $row.Utilization
            graphicsClockMHz    = ConvertTo-NullableIdleDouble $row.Clock
        })
    }
    $nextTarget = ($sampleIndex + 1) * $IntervalMilliseconds
    $remaining = $nextTarget - [int][Math]::Round($clock.Elapsed.TotalMilliseconds)
    if ($sampleIndex -lt $sampleTarget - 1 -and $remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
}
$clock.Stop()

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
    runId         = 'idle-' + [Guid]::NewGuid().ToString('N')
    createdUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    source        = 'live'
    condition     = $Condition
    privacy       = [pscustomobject][ordered]@{
        containsGpuUuid     = $false
        containsMachineName = $false
        containsUserName    = $false
        containsPaths       = $false
        containsRawCommand  = $false
    }
    profile       = [pscustomobject][ordered]@{
        label                     = $ProfileLabel
        clockPolicy               = $ClockPolicy
        graphicsClockMaximumMHz   = if ($null -eq $GraphicsClockMaximumMHz) { $null } else { [double]$GraphicsClockMaximumMHz }
    }
    protocol      = [pscustomobject][ordered]@{
        settleSeconds        = $SettleSeconds
        sampleSeconds        = $SampleSeconds
        intervalMilliseconds = $IntervalMilliseconds
        repetition           = $Repetition
    }
    result        = [pscustomobject][ordered]@{
        status = 'passed'
        error  = $null
    }
    gpus          = @($gpus)
}

Assert-CAIdlePowerRun -Run $run | Out-Null
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
    Condition = $Condition
    Gpus = $gpus.Count
    SamplesPerGpu = $sampleTarget
    HardwareWrites = $false
    ContainsMachineIdentifiers = $false
}
