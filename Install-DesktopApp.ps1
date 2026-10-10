[CmdletBinding()]
param(
    [string]$ExecutablePath = (Join-Path $PSScriptRoot 'CAAutoConfig.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'Install-SystemOverlay.ps1'
if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    throw "The self-contained desktop executable is missing: $ExecutablePath"
}
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "The overlay installer is missing: $installer"
}

& $installer -CompiledExecutablePath $ExecutablePath
