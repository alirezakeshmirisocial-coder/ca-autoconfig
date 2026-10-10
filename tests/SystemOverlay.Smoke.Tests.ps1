[CmdletBinding()]
param([switch]$DesktopRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop' -and -not $DesktopRun) {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -DesktopRun
    exit $LASTEXITCODE
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $projectRoot 'Start-SystemOverlay.ps1'
$source = Join-Path $projectRoot 'SystemOverlay.cs'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$compileResult = & $runner -CompileOnly
Assert-True ($null -ne $compileResult) 'The overlay compile check returned no result.'
Assert-True ([string]$compileResult.Status -eq 'Compiled') 'SystemOverlay.cs did not compile.'
Assert-True ([string]$compileResult.Type -eq 'CA.SystemOverlay.Program') 'The expected overlay entry point was not created.'

$sourceText = Get-Content -LiteralPath $source -Raw
foreach ($requiredFragment in @(
    'internal sealed class MonitorMapControl',
    'internal sealed class HotkeyCaptureBox',
    'RegisterHotKey',
    'LockBoundsPhysical',
    'power.draw',
    'power.default_limit',
    'power.min_limit',
    'power.max_limit',
    'CalculateSafeStartingPoint',
    'Starting points stay inside NVIDIA''s reported range'
)) {
    Assert-True ($sourceText.Contains($requiredFragment)) "Missing overlay feature marker: $requiredFragment"
}

$assembly = [CA.SystemOverlay.Program].Assembly
$settingsType = $assembly.GetType('CA.SystemOverlay.OverlaySettings', $true)
$storeType = $assembly.GetType('CA.SystemOverlay.SettingsStore', $true)
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('ca-overlay-test-' + [Guid]::NewGuid().ToString('N'))
$settingsPath = Join-Path $temporaryRoot 'settings.json'

try {
    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
    $settings = [Activator]::CreateInstance($settingsType)
    $settingsType.GetProperty('TargetDeviceName').SetValue($settings, '\\.\DISPLAY_TEST', $null)
    $settingsType.GetProperty('HasCustomPosition').SetValue($settings, $true, $null)
    $settingsType.GetProperty('PositionX').SetValue($settings, 44, $null)
    $settingsType.GetProperty('PositionY').SetValue($settings, 88, $null)
    $settingsType.GetProperty('Opacity').SetValue($settings, 0.76, $null)
    $settingsType.GetProperty('HotkeyModifiers').SetValue($settings, 6, $null)
    $settingsType.GetProperty('HotkeyKey').SetValue($settings, [int][Windows.Forms.Keys]::H, $null)

    $constructorFlags = [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::NonPublic
    $storeConstructor = $storeType.GetConstructor($constructorFlags, $null, [Type[]]@([string]), $null)
    Assert-True ($null -ne $storeConstructor) 'SettingsStore constructor was not found.'
    $store = $storeConstructor.Invoke([object[]](,[string]$settingsPath))
    $storeType.GetMethod('Save').Invoke($store, @($settings)) | Out-Null
    Assert-True (Test-Path -LiteralPath $settingsPath -PathType Leaf) 'Settings were not persisted.'
    $loaded = $storeType.GetMethod('Load').Invoke($store, @('', 0.82))
    Assert-True ([string]$settingsType.GetProperty('TargetDeviceName').GetValue($loaded, $null) -eq '\\.\DISPLAY_TEST') 'Target display did not round-trip.'
    Assert-True ([int]$settingsType.GetProperty('PositionX').GetValue($loaded, $null) -eq 44) 'HUD X position did not round-trip.'
    Assert-True ([int]$settingsType.GetProperty('PositionY').GetValue($loaded, $null) -eq 88) 'HUD Y position did not round-trip.'
    Assert-True ([int]$settingsType.GetProperty('HotkeyModifiers').GetValue($loaded, $null) -eq 6) 'Shortcut modifiers did not round-trip.'
    Assert-True ([int]$settingsType.GetProperty('HotkeyKey').GetValue($loaded, $null) -eq [int][Windows.Forms.Keys]::H) 'Shortcut key did not round-trip.'
}
finally {
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        Remove-Item -LiteralPath $settingsPath -Force
    }
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Force
    }
}

$nvidiaSmi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
if (Test-Path -LiteralPath $nvidiaSmi -PathType Leaf) {
    $rows = @(& $nvidiaSmi --query-gpu=index,uuid,power.draw,power.limit,power.default_limit,power.min_limit,power.max_limit,temperature.gpu --format=csv,noheader,nounits)
    Assert-True ($LASTEXITCODE -eq 0) 'nvidia-smi telemetry query failed.'
    Assert-True ($rows.Count -gt 0) 'nvidia-smi returned no GPUs.'
    foreach ($row in $rows) {
        $parts = @($row -split ',' | ForEach-Object { $_.Trim() })
        Assert-True ($parts.Count -ge 8) "Incomplete NVIDIA telemetry row: $row"
        $currentLimit = [double]::Parse($parts[3], [Globalization.CultureInfo]::InvariantCulture)
        $minimumLimit = [double]::Parse($parts[5], [Globalization.CultureInfo]::InvariantCulture)
        $maximumLimit = [double]::Parse($parts[6], [Globalization.CultureInfo]::InvariantCulture)
        Assert-True ($currentLimit -ge $minimumLimit -and $currentLimit -le $maximumLimit) "GPU power limit is outside its reported supported range: $row"
    }
}

[pscustomobject]@{
    Status              = 'Passed'
    Compile             = $true
    SettingsRoundTrip   = $true
    NvidiaTelemetryRows = if (Test-Path -LiteralPath $nvidiaSmi) { $rows.Count } else { 0 }
}
