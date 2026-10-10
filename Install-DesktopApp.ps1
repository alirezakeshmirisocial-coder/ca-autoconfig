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
$controlPanelSource = Join-Path $PSScriptRoot 'CA-ControlPanel.ps1'
if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    throw "The self-contained desktop executable is missing: $ExecutablePath"
}
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "The overlay installer is missing: $installer"
}
if (-not (Test-Path -LiteralPath $controlPanelSource -PathType Leaf)) {
    throw "The control panel is missing: $controlPanelSource"
}

$installerParameters = @{ CompiledExecutablePath = $ExecutablePath }
if (-not [string]::IsNullOrWhiteSpace($TargetDeviceName)) {
    $installerParameters.TargetDeviceName = $TargetDeviceName
}
& $installer @installerParameters

$installPath = Join-Path $env:LOCALAPPDATA 'CASystemOverlay'
$controlPanelTarget = Join-Path $installPath 'CA-ControlPanel.ps1'
Copy-Item -LiteralPath $controlPanelSource -Destination $controlPanelTarget -Force

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'CA AutoConfig.lnk'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powerShellPath
$shortcut.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$controlPanelTarget`""
$shortcut.WorkingDirectory = $installPath
$shortcut.Description = 'Open the CA AutoConfig control panel'
$shortcut.IconLocation = "$powerShellPath,0"
$shortcut.Save()

[pscustomobject]@{
    ControlPanel = $controlPanelTarget
    Shortcut     = $shortcutPath
} | Format-List
