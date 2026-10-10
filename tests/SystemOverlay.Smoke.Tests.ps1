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
    'CurrentSchemaVersion',
    'power.draw',
    'power.default_limit',
    'power.min_limit',
    'power.max_limit',
    'RecordedNvidiaTelemetrySource',
    'GPU TELEMETRY PARTIAL',
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
    Assert-True ([int]$settingsType.GetProperty('SchemaVersion').GetValue($settings, $null) -eq 1) 'Settings schema version is not initialized.'
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
    Assert-True ([int]$settingsType.GetProperty('SchemaVersion').GetValue($loaded, $null) -eq 1) 'Settings schema version did not round-trip.'
    Assert-True ([string]$settingsType.GetProperty('TargetDeviceName').GetValue($loaded, $null) -eq '\\.\DISPLAY_TEST') 'Target display did not round-trip.'
    Assert-True ([int]$settingsType.GetProperty('PositionX').GetValue($loaded, $null) -eq 44) 'HUD X position did not round-trip.'
    Assert-True ([int]$settingsType.GetProperty('PositionY').GetValue($loaded, $null) -eq 88) 'HUD Y position did not round-trip.'
    Assert-True ([int]$settingsType.GetProperty('HotkeyModifiers').GetValue($loaded, $null) -eq 6) 'Shortcut modifiers did not round-trip.'
    Assert-True ([int]$settingsType.GetProperty('HotkeyKey').GetValue($loaded, $null) -eq [int][Windows.Forms.Keys]::H) 'Shortcut key did not round-trip.'

    [IO.File]::WriteAllText($settingsPath, '{"SchemaVersion":99,"TargetDeviceName":"future-display"}', (New-Object Text.UTF8Encoding($false)))
    $futureStore = $storeConstructor.Invoke([object[]](,[string]$settingsPath))
    $futureLoaded = $storeType.GetMethod('Load').Invoke($futureStore, @('safe-fallback', 0.82))
    Assert-True ([string]$settingsType.GetProperty('TargetDeviceName').GetValue($futureLoaded, $null) -eq 'safe-fallback') 'A newer schema did not fall back safely.'
    $futureWriteBlocked = $false
    try {
        $storeType.GetMethod('Save').Invoke($futureStore, @($futureLoaded)) | Out-Null
    }
    catch {
        $futureWriteBlocked = $_.Exception.InnerException.Message -match 'newer CA AutoConfig version'
    }
    Assert-True $futureWriteBlocked 'A newer settings schema could be overwritten.'
    Assert-True ((Get-Content -Raw -LiteralPath $settingsPath) -match '"SchemaVersion":99') 'The newer settings file was modified.'
}
finally {
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        Remove-Item -LiteralPath $settingsPath -Force
    }
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Force
    }
}

$sourceInterface = $assembly.GetType('CA.SystemOverlay.INvidiaTelemetrySource', $true)
$recordedSourceType = $assembly.GetType('CA.SystemOverlay.RecordedNvidiaTelemetrySource', $true)
$providerType = $assembly.GetType('CA.SystemOverlay.MetricsProvider', $true)
$snapshotType = $assembly.GetType('CA.SystemOverlay.MetricSnapshot', $true)
$gpuMetricType = $assembly.GetType('CA.SystemOverlay.GpuMetric', $true)
$recordedConstructor = $recordedSourceType.GetConstructor($constructorFlags, $null, [Type[]]@([bool], [bool], [bool], [string]), $null)
$providerConstructor = $providerType.GetConstructor($constructorFlags, $null, [Type[]]@($sourceInterface, [string], [DateTime]), $null)
$collectGpu = $providerType.GetMethod('CollectGpuSnapshotOnce', $constructorFlags)
Assert-True ($null -ne $recordedConstructor -and $null -ne $providerConstructor -and $null -ne $collectGpu) 'Simulated NVIDIA provider test surface is missing.'

function Get-FieldValue {
    param($Object, [Type]$Type, [string]$Name)
    $value = $Type.GetField($Name, $constructorFlags).GetValue($Object)
    Write-Output -NoEnumerate $value
}

function Invoke-RecordedGpuSnapshot {
    param(
        [bool]$Available,
        [bool]$Success,
        [bool]$TimedOut,
        [string]$Output,
        [string]$StatePath
    )
    $sourceInstance = $recordedConstructor.Invoke([object[]]@($Available, $Success, $TimedOut, $Output))
    $provider = $providerConstructor.Invoke([object[]]@($sourceInstance, [string]$StatePath, [DateTime]::UtcNow.AddMinutes(-10)))
    try { return $collectGpu.Invoke($provider, $null) }
    finally { $providerType.GetMethod('Dispose').Invoke($provider, $null) | Out-Null }
}

$providerRoot = Join-Path ([IO.Path]::GetTempPath()) ('ca-overlay-provider-test-' + [Guid]::NewGuid().ToString('N'))
$statePath = Join-Path $providerRoot 'gpu-limits-state.json'
try {
    New-Item -ItemType Directory -Force -Path $providerRoot | Out-Null
    $stateJson = @{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status = 'applied'
        results = @(
            @{ index = 0; uuid = 'GPU-00000000-0000-0000-0000-000000000000'; maxGraphicsClockMHz = 1700; powerLimitWatts = 280.0 },
            @{ index = 1; uuid = 'GPU-11111111-1111-1111-1111-111111111111'; maxGraphicsClockMHz = 1700; powerLimitWatts = 280.0 }
        )
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($statePath, $stateJson, (New-Object Text.UTF8Encoding($false)))

    $validOutput = @(
        '0, GPU-00000000-0000-0000-0000-000000000000, NVIDIA GeForce RTX 3090, 100, 40, 20000, 24576, 250, 280, 350, 100, 370, 60, 1695',
        '1, GPU-11111111-1111-1111-1111-111111111111, NVIDIA GeForce RTX 3090, 98, 35, 19800, 24576, 240, 280, 350, 100, 370, 61, 1680'
    ) -join "`n"
    $validSnapshot = Invoke-RecordedGpuSnapshot $true $true $false $validOutput $statePath
    Assert-True ([bool](Get-FieldValue $validSnapshot $snapshotType 'GpuLimitsHealthy')) 'Valid recorded telemetry did not verify the current-boot profile.'
    $validDetail = [string](Get-FieldValue $validSnapshot $snapshotType 'GpuLimitDetail')
    Assert-True ($validDetail -match '^ACTIVE.+1700 MHz / 280 W$') "Valid recorded telemetry produced the wrong profile detail: $validDetail"
    $validGpus = Get-FieldValue $validSnapshot $snapshotType 'Gpus'
    Assert-True ($validGpus.Count -eq 2) 'Valid recorded telemetry did not return two GPUs.'
    Assert-True ([string](Get-FieldValue $validGpus[0] $gpuMetricType 'Name') -eq 'RTX 3090') 'GPU name normalization failed.'

    $reorderedOutput = @(
        '7, GPU-00000000-0000-0000-0000-000000000000, NVIDIA GeForce RTX 3090, 100, 40, 20000, 24576, 250, 280, 350, 100, 370, 60, 1695',
        '4, GPU-11111111-1111-1111-1111-111111111111, NVIDIA GeForce RTX 3090, 98, 35, 19800, 24576, 240, 280, 350, 100, 370, 61, 1680'
    ) -join "`n"
    $reorderedSnapshot = Invoke-RecordedGpuSnapshot $true $true $false $reorderedOutput $statePath
    Assert-True ([bool](Get-FieldValue $reorderedSnapshot $snapshotType 'GpuLimitsHealthy')) 'UUID-pinned profile failed after simulated GPU index reordering.'

    $wrongIdentityOutput = $validOutput.Replace('GPU-00000000-0000-0000-0000-000000000000', 'GPU-22222222-2222-2222-2222-222222222222')
    $wrongIdentitySnapshot = Invoke-RecordedGpuSnapshot $true $true $false $wrongIdentityOutput $statePath
    Assert-True (-not [bool](Get-FieldValue $wrongIdentitySnapshot $snapshotType 'GpuLimitsHealthy')) 'A different GPU at the old numeric index was accepted for a UUID-pinned profile.'
    Assert-True ([string](Get-FieldValue $wrongIdentitySnapshot $snapshotType 'GpuLimitDetail') -eq 'PROFILE GPU IS MISSING') 'UUID identity mismatch did not fail closed.'

    $legacyStateJson = @{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status = 'applied'
        results = @(
            @{ index = 0; maxGraphicsClockMHz = 1700; powerLimitWatts = 280.0 },
            @{ index = 1; maxGraphicsClockMHz = 1700; powerLimitWatts = 280.0 }
        )
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($statePath, $legacyStateJson, (New-Object Text.UTF8Encoding($false)))
    $legacySnapshot = Invoke-RecordedGpuSnapshot $true $true $false $validOutput $statePath
    Assert-True ([bool](Get-FieldValue $legacySnapshot $snapshotType 'GpuLimitsHealthy')) 'Legacy index-only state compatibility failed.'

    $invalidIdentityStateJson = @{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status = 'applied'
        results = @(@{ index = 0; uuid = 'not-a-gpu-uuid'; maxGraphicsClockMHz = 1700; powerLimitWatts = 280.0 })
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($statePath, $invalidIdentityStateJson, (New-Object Text.UTF8Encoding($false)))
    $invalidIdentityStateSnapshot = Invoke-RecordedGpuSnapshot $true $true $false $validOutput $statePath
    Assert-True ([string](Get-FieldValue $invalidIdentityStateSnapshot $snapshotType 'GpuLimitDetail') -eq 'LIMIT PROFILE IS INVALID') 'Malformed UUID state did not fail closed.'

    $duplicateIdentityStateJson = @{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status = 'applied'
        results = @(
            @{ index = 0; uuid = 'GPU-00000000-0000-0000-0000-000000000000'; maxGraphicsClockMHz = 1700; powerLimitWatts = 280.0 },
            @{ index = 1; uuid = 'GPU-00000000-0000-0000-0000-000000000000'; maxGraphicsClockMHz = 1700; powerLimitWatts = 280.0 }
        )
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($statePath, $duplicateIdentityStateJson, (New-Object Text.UTF8Encoding($false)))
    $duplicateIdentityStateSnapshot = Invoke-RecordedGpuSnapshot $true $true $false $validOutput $statePath
    Assert-True ([string](Get-FieldValue $duplicateIdentityStateSnapshot $snapshotType 'GpuLimitDetail') -eq 'LIMIT PROFILE IS INVALID') 'Duplicate UUID state did not fail closed.'

    $missingSnapshot = Invoke-RecordedGpuSnapshot $false $false $false '' $statePath
    Assert-True ([string](Get-FieldValue $missingSnapshot $snapshotType 'GpuLimitDetail') -eq 'NVIDIA-SMI MISSING') 'Missing NVIDIA source did not fail closed.'

    $timeoutSnapshot = Invoke-RecordedGpuSnapshot $true $false $true '' $statePath
    Assert-True ([string](Get-FieldValue $timeoutSnapshot $snapshotType 'GpuLimitDetail') -eq 'GPU QUERY TIMEOUT') 'Timed-out NVIDIA source did not fail closed.'

    $failedSnapshot = Invoke-RecordedGpuSnapshot $true $false $false '' $statePath
    Assert-True ([string](Get-FieldValue $failedSnapshot $snapshotType 'GpuLimitDetail') -eq 'GPU DATA UNAVAILABLE') 'Failed NVIDIA source did not fail closed.'

    $emptySnapshot = Invoke-RecordedGpuSnapshot $true $true $false '' $statePath
    Assert-True ([string](Get-FieldValue $emptySnapshot $snapshotType 'GpuLimitDetail') -eq 'NO NVIDIA GPUS REPORTED') 'Empty successful NVIDIA output was not distinguished from valid telemetry.'

    $partialSnapshot = Invoke-RecordedGpuSnapshot $true $true $false ($validOutput.Split("`n")[0] + "`n1, broken") $statePath
    Assert-True ([string](Get-FieldValue $partialSnapshot $snapshotType 'GpuLimitDetail') -eq 'GPU TELEMETRY PARTIAL') 'Partially malformed telemetry did not fail closed.'
    Assert-True ((Get-FieldValue $partialSnapshot $snapshotType 'Gpus').Count -eq 1) 'The valid row in partial telemetry was not retained for diagnosis.'

    $invalidSnapshot = Invoke-RecordedGpuSnapshot $true $true $false 'not-an-index, GPU-X, broken, nope, nope, nope, nope, nope, nope, nope, nope, nope, nope, nope' $statePath
    Assert-True ([string](Get-FieldValue $invalidSnapshot $snapshotType 'GpuLimitDetail') -eq 'GPU TELEMETRY INVALID') 'Fully malformed telemetry did not fail closed.'

    $naOutput = '0, GPU-0, NVIDIA GeForce RTX 3090, N/A, N/A, N/A, N/A, N/A, N/A, N/A, N/A, N/A, N/A, N/A'
    $naSnapshot = Invoke-RecordedGpuSnapshot $true $true $false $naOutput (Join-Path $providerRoot 'missing-state.json')
    $naGpus = Get-FieldValue $naSnapshot $snapshotType 'Gpus'
    Assert-True ($naGpus.Count -eq 1) 'A valid GPU row with explicit N/A fields was discarded.'
    Assert-True ([int](Get-FieldValue $naGpus[0] $gpuMetricType 'LoadPercent') -eq -1) 'Missing load was converted to a real percentage.'
    Assert-True ([int](Get-FieldValue $naGpus[0] $gpuMetricType 'TemperatureC') -eq -1) 'Missing temperature was converted to a real reading.'
    Assert-True ([double](Get-FieldValue $naGpus[0] $gpuMetricType 'SuggestedPowerLimitWatts') -lt 0) 'Missing vendor range produced a power recommendation.'
}
finally {
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { Remove-Item -LiteralPath $statePath -Force }
    if (Test-Path -LiteralPath $providerRoot -PathType Container) { Remove-Item -LiteralPath $providerRoot -Force }
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
    SimulatedNvidiaCases = 13
    NvidiaTelemetryRows = if (Test-Path -LiteralPath $nvidiaSmi) { $rows.Count } else { 0 }
}
