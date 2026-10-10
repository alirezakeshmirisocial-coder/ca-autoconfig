[CmdletBinding()]
param(
    [string[]]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PowerCurve.psm1') -Force

if ($DryRun) {
    $InputPath = @(
        (Join-Path $PSScriptRoot 'fixtures\dual-3090-280w.json'),
        (Join-Path $PSScriptRoot 'fixtures\dual-3090-350w.json')
    )
}
if (@($InputPath).Count -lt 2) { throw 'Provide at least two benchmark run paths or use -DryRun.' }

$runs = foreach ($path in $InputPath) {
    $resolved = Resolve-Path -LiteralPath $path -ErrorAction Stop
    Get-Content -Raw -LiteralPath $resolved.Path | ConvertFrom-Json
}
$svg = New-CAPowerCurveCardSvg -Runs @($runs)
$fullOutput = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $fullOutput
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}
[IO.File]::WriteAllText($fullOutput, $svg, (New-Object Text.UTF8Encoding($false)))

[pscustomobject]@{
    Status = 'CardCreated'
    Runs = @($runs).Count
    Source = [string]$runs[0].source
    Output = $fullOutput
    Bytes = (Get-Item -LiteralPath $fullOutput).Length
    HardwareWrites = $false
}
