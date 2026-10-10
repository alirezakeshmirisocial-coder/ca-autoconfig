[CmdletBinding()]
param([switch]$ReinstallGpuTask)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Install-PresenceMonitor.ps1')
& (Join-Path $PSScriptRoot 'Install-SystemOverlay.ps1')

$gpuResultPath = Join-Path $env:ProgramData 'CAGpuLimits\install-result.json'
$gpuInstalled = $false
if (Test-Path -LiteralPath $gpuResultPath -PathType Leaf) {
    try { $gpuInstalled = [string](Get-Content -Raw -LiteralPath $gpuResultPath | ConvertFrom-Json).status -eq 'installed' }
    catch { $gpuInstalled = $false }
}
if ($ReinstallGpuTask -or -not $gpuInstalled) {
    & (Join-Path $PSScriptRoot 'Install-GpuLimits.ps1') -MaxGraphicsClockMHz 1700 -PowerLimitWatts 280
}

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'CA AutoConfig.lnk'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$controlPanelPath = Join-Path $PSScriptRoot 'CA-ControlPanel.ps1'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powerShellPath
$shortcut.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$controlPanelPath`""
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Control CA Presence Monitor and NVIDIA GPU limits'
$shortcut.IconLocation = "$powerShellPath,0"
$shortcut.Save()

[pscustomobject]@{
    PresenceTask = 'CA Presence Monitor (NO LOCK)'
    OverlayTask  = 'CA System Overlay'
    GpuTask      = 'CA GPU Limits'
    Shortcut     = $shortcutPath
    AutoStart    = $true
    CameraWindow = 'Starts and stays minimized until the user restores it'
    HardwareHud  = 'Transparent, click-through, monitor 3 bottom-left'
    NoLock       = $true
} | Format-List
