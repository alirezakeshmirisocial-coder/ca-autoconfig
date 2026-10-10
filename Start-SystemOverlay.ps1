[CmdletBinding()]
param(
    [ValidateRange(1000, 60000)]
    [int]$PollMilliseconds = 2000,

    [ValidateRange(0.58, 0.95)]
    [double]$Opacity = 0.82,

    [string]$TargetDeviceName = '',

    [string]$SettingsPath = (Join-Path $env:LOCALAPPDATA 'CAAutoConfig\settings.json'),

    [switch]$CompileOnly,

    [switch]$OpenSettings,

    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'CASystemOverlay\overlay-errors.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'SystemOverlay.cs'
$nvidiaSmi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
$gpuStatePath = Join-Path $env:ProgramData 'CAGpuLimits\gpu-limits-state.json'

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Management
    Add-Type -AssemblyName System.Web.Extensions
    if (-not ('CA.SystemOverlay.Program' -as [type])) {
        $webExtensionsPath = [System.Web.Script.Serialization.JavaScriptSerializer].Assembly.Location
        Add-Type -Path $sourcePath -ReferencedAssemblies @(
            'System.dll',
            'System.Core.dll',
            'System.Drawing.dll',
            'System.Management.dll',
            $webExtensionsPath,
            'System.Windows.Forms.dll'
        )
    }
    if ($CompileOnly) {
        [pscustomobject]@{
            Status = 'Compiled'
            Type   = [CA.SystemOverlay.Program].FullName
        }
        return
    }
    if ($OpenSettings -and [CA.SystemOverlay.Program]::RequestSettings()) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($TargetDeviceName)) {
        $screens = [System.Windows.Forms.Screen]::AllScreens
        if ($screens.Count -ge 3) {
            $TargetDeviceName = $screens[2].DeviceName
        }
        elseif ($null -ne [System.Windows.Forms.Screen]::PrimaryScreen) {
            $TargetDeviceName = [System.Windows.Forms.Screen]::PrimaryScreen.DeviceName
        }
    }
    [CA.SystemOverlay.Program]::Run($nvidiaSmi, $gpuStatePath, $SettingsPath, $PollMilliseconds, $Opacity, $TargetDeviceName, $OpenSettings.IsPresent)
}
catch {
    $directory = Split-Path -Parent $LogPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ("{0}`t{1}" -f [DateTime]::UtcNow.ToString('o'), $_.Exception.ToString())
    exit 1
}
