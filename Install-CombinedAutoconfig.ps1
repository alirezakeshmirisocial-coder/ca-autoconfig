[CmdletBinding()]
param(
    [switch]$InstallPresenceMonitor,

    [switch]$InstallGpuLimits,

    [switch]$ReinstallGpuTask,

    [ValidateNotNullOrEmpty()]
    [string]$GpuIndexList,

    [int]$MaxGraphicsClockMHz,

    [int]$PowerLimitWatts,

    [switch]$AcceptHardwareRisk
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Install-SystemOverlay.ps1')

if ($InstallPresenceMonitor) {
    & (Join-Path $PSScriptRoot 'Install-PresenceMonitor.ps1')
}

$gpuResultPath = Join-Path $env:ProgramData 'CAGpuLimits\install-result.json'
$gpuInstalled = $false
if (Test-Path -LiteralPath $gpuResultPath -PathType Leaf) {
    try { $gpuInstalled = [string](Get-Content -Raw -LiteralPath $gpuResultPath | ConvertFrom-Json).status -eq 'installed' }
    catch { $gpuInstalled = $false }
}
if ($InstallGpuLimits -or $ReinstallGpuTask) {
    if ([string]::IsNullOrWhiteSpace($GpuIndexList) -or
        $MaxGraphicsClockMHz -lt 300 -or $MaxGraphicsClockMHz -gt 3000 -or
        $PowerLimitWatts -lt 50 -or $PowerLimitWatts -gt 1000) {
        throw 'GPU installation requires explicit -GpuIndexList, -MaxGraphicsClockMHz, and -PowerLimitWatts values.'
    }
    if (-not $AcceptHardwareRisk) {
        throw 'GPU installation is opt-in. Review the board-specific limits and add -AcceptHardwareRisk.'
    }
    & (Join-Path $PSScriptRoot 'Install-GpuLimits.ps1') `
        -GpuIndexList $GpuIndexList `
        -MaxGraphicsClockMHz $MaxGraphicsClockMHz `
        -PowerLimitWatts $PowerLimitWatts `
        -AcceptHardwareRisk
    $gpuInstalled = $true
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
    PresenceTask = if ($InstallPresenceMonitor) { 'CA Presence Monitor (NO LOCK)' } else { 'Not installed by this run (opt-in)' }
    OverlayTask  = 'CA System Overlay'
    GpuTask      = if ($gpuInstalled) { 'CA GPU Limits' } else { 'Not installed (opt-in)' }
    Shortcut     = $shortcutPath
    AutoStart    = $true
    CameraWindow = if ($InstallPresenceMonitor) { 'Starts minimized until the user restores it' } else { 'Not installed by this run' }
    HardwareHud  = 'Transparent and click-through; display and position are user-configurable'
    NoLock       = $true
} | Format-List
