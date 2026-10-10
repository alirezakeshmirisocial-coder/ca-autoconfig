[CmdletBinding()]
param(
    [string[]]$InputPath = @(),
    [string]$OutputPath = '',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PowerCurve.psm1') -Force

if ($DryRun -and $InputPath.Count -gt 0) { throw '-DryRun cannot be combined with -InputPath.' }
if ($DryRun) {
    $InputPath = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures') -Filter '*.json' -File | Sort-Object Name | ForEach-Object FullName)
}
if ($InputPath.Count -eq 0) { throw 'Provide one or more schema-v1/v2 run files, or use -DryRun.' }

$runs = foreach ($path in $InputPath) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Benchmark run not found: $path" }
    $run = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    Assert-CAPowerCurveRun -Run $run | Out-Null
    $run
}

$report = New-CAPowerCurveMarkdown -Runs @($runs)
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $fullOutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }
    $report | Set-Content -LiteralPath $fullOutputPath -Encoding UTF8
}

[pscustomobject]@{
    Status = 'Reported'
    Runs = @($runs).Count
    Output = if ([string]::IsNullOrWhiteSpace($OutputPath)) { $null } else { [IO.Path]::GetFullPath($OutputPath) }
    Markdown = $report
    HardwareWrites = $false
}
