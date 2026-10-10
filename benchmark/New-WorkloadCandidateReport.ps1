[CmdletBinding()]
param(
    [string[]]$InputPath,
    [string]$ReferenceProfile = '',
    [string]$CandidateProfile = '',
    [AllowNull()][Nullable[double]]$ExpectedGraphicsClockMaximumMHz,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [ValidateRange(1, 100)][int]$MinimumRepetitions = 3,
    [ValidateRange(1, 3600)][int]$MinimumSampleSeconds = 30,
    [ValidateRange(0, 100)][double]$MinimumPerformanceRetentionPercent = 90,
    [ValidateRange(0, 1000)][double]$MinimumEfficiencyGainPercent = 5,
    [ValidateRange(-50, 150)][double]$MaximumPeakTemperatureC = 85,
    [ValidateRange(0, 100)][double]$MinimumClockSampleUtilizationPercent = 50,
    [ValidateRange(1, 10000)][int]$MinimumClockSamplesPerGpuRun = 3,
    [ValidateRange(0, 100)][double]$MaximumClockSpreadPercent = 5,
    [ValidateRange(0, 1000)][double]$MaximumClockCeilingToleranceMHz = 30,

    [switch]$DryRun,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PowerAdvisor.psm1') -Force

if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "Output already exists: $OutputPath. Use -Force to replace it."
}

$runs = New-Object Collections.Generic.List[object]
if ($DryRun) {
    if ([string]::IsNullOrWhiteSpace($ReferenceProfile)) { $ReferenceProfile = 'GPU0 350 W + GPU1 350 W' }
    if ([string]::IsNullOrWhiteSpace($CandidateProfile)) { $CandidateProfile = 'GPU0 280 W + GPU1 280 W' }
    if ($null -eq $ExpectedGraphicsClockMaximumMHz) { $ExpectedGraphicsClockMaximumMHz = 1700 }
    $templates = @(
        (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\dual-3090-280w.json') | ConvertFrom-Json)
        (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\dual-3090-350w.json') | ConvertFrom-Json)
    )
    foreach ($template in $templates) {
        for ($repetition = 1; $repetition -le $MinimumRepetitions; $repetition++) {
            $copy = $template | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            $copy.runId = "$($copy.runId)-advisor-$repetition"
            $copy.protocol.repetition = $repetition
            foreach ($gpu in @($copy.gpus)) {
                $pattern = @($gpu.samples | ForEach-Object { $_ | ConvertTo-Json -Depth 4 | ConvertFrom-Json })
                $expanded = New-Object Collections.Generic.List[object]
                $sampleTarget = [int][Math]::Ceiling(($copy.protocol.sampleSeconds * 1000.0) / $copy.protocol.intervalMilliseconds)
                for ($sampleIndex = 0; $sampleIndex -lt $sampleTarget; $sampleIndex++) {
                    $sample = $pattern[$sampleIndex % $pattern.Count] | ConvertTo-Json -Depth 4 | ConvertFrom-Json
                    $sample.elapsedMilliseconds = $sampleIndex * [int]$copy.protocol.intervalMilliseconds
                    if ($null -eq $sample.graphicsClockMHz) { $sample.graphicsClockMHz = 1695 }
                    $expanded.Add($sample)
                }
                $gpu.samples = $expanded.ToArray()
            }
            $runs.Add($copy)
        }
    }
}
else {
    if ($null -eq $InputPath -or @($InputPath).Count -eq 0) { throw '-InputPath is required unless -DryRun is used.' }
    if ([string]::IsNullOrWhiteSpace($ReferenceProfile)) { throw '-ReferenceProfile is required unless -DryRun is used.' }
    if ([string]::IsNullOrWhiteSpace($CandidateProfile)) { throw '-CandidateProfile is required unless -DryRun is used.' }
    if ($null -eq $ExpectedGraphicsClockMaximumMHz) { throw '-ExpectedGraphicsClockMaximumMHz is required unless -DryRun is used.' }
    foreach ($path in @($InputPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Workload run was not found: $path" }
        $runs.Add((Get-Content -Raw -LiteralPath $path | ConvertFrom-Json))
    }
}

$parameters = @{
    Runs = $runs.ToArray()
    ReferenceProfile = $ReferenceProfile
    CandidateProfile = $CandidateProfile
    ExpectedGraphicsClockMaximumMHz = [double]$ExpectedGraphicsClockMaximumMHz
    MinimumRepetitions = $MinimumRepetitions
    MinimumSampleSeconds = $MinimumSampleSeconds
    MinimumPerformanceRetentionPercent = $MinimumPerformanceRetentionPercent
    MinimumEfficiencyGainPercent = $MinimumEfficiencyGainPercent
    MaximumPeakTemperatureC = $MaximumPeakTemperatureC
    MinimumClockSampleUtilizationPercent = $MinimumClockSampleUtilizationPercent
    MinimumClockSamplesPerGpuRun = $MinimumClockSamplesPerGpuRun
    MaximumClockSpreadPercent = $MaximumClockSpreadPercent
    MaximumClockCeilingToleranceMHz = $MaximumClockCeilingToleranceMHz
}
$gate = Test-CAWorkloadCandidate @parameters
$markdown = New-CAWorkloadCandidateMarkdown @parameters
$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $fullOutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}
$markdown | Set-Content -LiteralPath $fullOutputPath -Encoding UTF8

[pscustomobject]@{
    Status = 'ReportCreated'
    Output = $fullOutputPath
    Runs = $runs.Count
    GateStatus = $gate.GateStatus
    CanProceedPastWorkloadGate = $gate.CanProceedPastWorkloadGate
    HardwareReads = $false
    HardwareWrites = $false
}
