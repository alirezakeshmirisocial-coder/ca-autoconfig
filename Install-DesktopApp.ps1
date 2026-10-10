[CmdletBinding()]
param(
    [string]$ExecutablePath,
    [string]$TargetDeviceName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path $PSScriptRoot 'CAAutoConfig.exe'
}
$installer = Join-Path $PSScriptRoot 'Install-SystemOverlay.ps1'
if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    throw "The self-contained desktop executable is missing: $ExecutablePath"
}
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "The overlay installer is missing: $installer"
}

$installerParameters = @{ CompiledExecutablePath = $ExecutablePath }
if (-not [string]::IsNullOrWhiteSpace($TargetDeviceName)) {
    $installerParameters.TargetDeviceName = $TargetDeviceName
}
& $installer @installerParameters
