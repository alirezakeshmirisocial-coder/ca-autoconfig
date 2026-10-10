[CmdletBinding()]
param(
    [string[]]$InputPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [ValidateRange(1, 100)]
    [int]$MinimumRepetitions = 3,

    [ValidateRange(1, 3600)]
    [int]$MinimumSampleSeconds = 30,

    [ValidateRange(0, 100)]
    [double]$MaximumMeanUtilizationPercent = 5,

    [ValidateRange(0, 100)]
    [double]$MaximumP95UtilizationPercent = 15,

    [ValidateRange(0, 1000)]
    [double]$MaximumTotalIncreaseWatts = 5,

    [ValidateRange(0, 1000)]
    [double]$MaximumTotalIncreasePercent = 10,

    [ValidateRange(0, 1000)]
    [double]$MaximumPerGpuIncreaseWatts = 3,

    [ValidateRange(0, 1000)]
    [double]$MaximumPerGpuIncreasePercent = 15,

    [switch]$DryRun,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'IdlePower.psm1') -Force

if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "Output already exists: $OutputPath. Use -Force to replace it."
}

$runs = New-Object Collections.Generic.List[object]
if ($DryRun) {
    $templates = @(
        (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\idle-dual-3090-baseline.json') | ConvertFrom-Json)
        (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\idle-dual-3090-candidate.json') | ConvertFrom-Json)
    )
    foreach ($template in $templates) {
        for ($repetition = 1; $repetition -le $MinimumRepetitions; $repetition++) {
            $copy = $template | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            $copy.runId = "$($copy.runId)-$repetition"
            $copy.protocol.repetition = $repetition
            $runs.Add($copy)
        }
    }
}
else {
    if ($null -eq $InputPath -or @($InputPath).Count -eq 0) {
        throw '-InputPath is required unless -DryRun is used.'
    }
    foreach ($path in @($InputPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Idle-power run was not found: $path" }
        $runs.Add((Get-Content -Raw -LiteralPath $path | ConvertFrom-Json))
    }
}

$parameters = @{
    Runs = $runs.ToArray()
    MinimumRepetitions = $MinimumRepetitions
    MinimumSampleSeconds = $MinimumSampleSeconds
    MaximumMeanUtilizationPercent = $MaximumMeanUtilizationPercent
    MaximumP95UtilizationPercent = $MaximumP95UtilizationPercent
    MaximumTotalIncreaseWatts = $MaximumTotalIncreaseWatts
    MaximumTotalIncreasePercent = $MaximumTotalIncreasePercent
    MaximumPerGpuIncreaseWatts = $MaximumPerGpuIncreaseWatts
    MaximumPerGpuIncreasePercent = $MaximumPerGpuIncreasePercent
}
$gate = Test-CAIdlePowerRegression @parameters
$markdown = New-CAIdlePowerGateMarkdown @parameters
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
    CanProceedPastIdleGate = $gate.CanProceedPastIdleGate
    HardwareReads = -not $DryRun
    HardwareWrites = $false
}
