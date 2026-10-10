[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GpuIndexList,

    [ValidateRange(300, 3000)]
    [Nullable[int]]$MaxGraphicsClockMHz,

    [ValidateRange(50, 1000)]
    [Nullable[int]]$PowerLimitWatts,

    [switch]$AcknowledgePowerIncrease,

    [string]$NvidiaSmiPath = (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),

    [string]$FixtureCsvPath = '',

    [switch]$SkipMigrationInspection
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hasPower = $PSBoundParameters.ContainsKey('PowerLimitWatts')
$hasClock = $PSBoundParameters.ContainsKey('MaxGraphicsClockMHz')
$source = if ([string]::IsNullOrWhiteSpace($FixtureCsvPath)) { 'live' } else { 'fixture' }
if ($SkipMigrationInspection -and $source -ne 'fixture') {
    throw 'SkipMigrationInspection is available only for deterministic fixture tests.'
}

$indices = @()
foreach ($token in @($GpuIndexList -split ',')) {
    $index = 0
    if ([string]::IsNullOrWhiteSpace($token) -or -not [int]::TryParse($token.Trim(), [ref]$index) -or $index -lt 0) {
        throw "Invalid GPU index list '$GpuIndexList'. Use unique non-negative indices such as 0,1."
    }
    $indices += $index
}
if (@($indices | Select-Object -Unique).Count -ne $indices.Count) { throw 'GPU indices must not contain duplicates.' }

if ($source -eq 'fixture') {
    if (-not (Test-Path -LiteralPath $FixtureCsvPath -PathType Leaf)) { throw "Fixture CSV is missing: $FixtureCsvPath" }
    $lines = @(Get-Content -LiteralPath $FixtureCsvPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
else {
    if (-not (Test-Path -LiteralPath $NvidiaSmiPath -PathType Leaf)) { throw "nvidia-smi was not found: $NvidiaSmiPath" }
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = (& $NvidiaSmiPath `
            '--query-gpu=index,name,power.draw,power.limit,power.default_limit,power.min_limit,power.max_limit,clocks.gr,clocks.max.gr' `
            '--format=csv,noheader,nounits' 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    if ($exitCode -ne 0) { throw "nvidia-smi inventory query failed with exit code $exitCode." }
    $lines = @($raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function ConvertTo-FiniteDouble {
    param([string]$Value, [string]$Label)
    $number = 0.0
    if (-not [double]::TryParse($Value.Trim(), [Globalization.NumberStyles]'Float', [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw "Invalid $Label telemetry."
    }
    return $number
}

function Get-SafePowerStartingPoint {
    param([double]$Minimum, [double]$Current, [double]$Default)
    if ($Minimum -le 0 -or $Default -le 0 -or $Minimum -gt $Default) { return $null }
    $candidate = [Math]::Round(($Default * 0.75) / 5.0, [MidpointRounding]::AwayFromZero) * 5.0
    $candidate = [Math]::Max($Minimum, [Math]::Min($Default, $candidate))
    if ($Current -ge $Minimum -and $Current -lt $Default) { $candidate = [Math]::Min($candidate, $Current) }
    return $candidate
}

$inventory = @()
foreach ($line in $lines) {
    $parts = @($line -split ',' | ForEach-Object { $_.Trim() })
    if ($parts.Count -ne 9) { throw 'nvidia-smi returned an unexpected inventory field count.' }
    $index = -1
    if (-not [int]::TryParse($parts[0], [ref]$index) -or $index -lt 0) { throw 'nvidia-smi returned an invalid GPU index.' }
    $minimumPower = ConvertTo-FiniteDouble $parts[5] 'minimum power'
    $maximumPower = ConvertTo-FiniteDouble $parts[6] 'maximum power'
    $defaultPower = ConvertTo-FiniteDouble $parts[4] 'default power'
    $currentPower = ConvertTo-FiniteDouble $parts[3] 'current power'
    $inventory += [pscustomobject][ordered]@{
        Index = $index
        Name = [string]$parts[1]
        PowerDrawWatts = ConvertTo-FiniteDouble $parts[2] 'power draw'
        CurrentPowerLimitWatts = $currentPower
        DefaultPowerLimitWatts = $defaultPower
        MinimumPowerLimitWatts = $minimumPower
        MaximumPowerLimitWatts = $maximumPower
        CurrentGraphicsClockMHz = ConvertTo-FiniteDouble $parts[7] 'current graphics clock'
        MaximumGraphicsClockMHz = ConvertTo-FiniteDouble $parts[8] 'maximum graphics clock'
        SuggestedPowerStartingPointWatts = Get-SafePowerStartingPoint $minimumPower $currentPower $defaultPower
    }
}

$selected = @()
foreach ($index in $indices) {
    $matches = @($inventory | Where-Object { $_.Index -eq $index })
    if ($matches.Count -ne 1) { throw "GPU index $index was not reported exactly once by nvidia-smi." }
    $selected += $matches[0]
}

$profileReasonCodes = New-Object Collections.Generic.List[string]
$migrationReasonCodes = New-Object Collections.Generic.List[string]
$warnings = New-Object Collections.Generic.List[string]
if ($hasPower -xor $hasClock) { $profileReasonCodes.Add('incomplete-proposed-profile') }
if (-not $hasPower -and -not $hasClock) { $warnings.Add('No profile was proposed; this is an inventory-only plan.') }

$sharedMinimum = [double](($selected | Measure-Object -Property MinimumPowerLimitWatts -Maximum).Maximum)
$suggestionCeiling = [double](($selected | Measure-Object -Property SuggestedPowerStartingPointWatts -Minimum).Minimum)
$suggestedSharedPower = if ($sharedMinimum -le $suggestionCeiling) { $suggestionCeiling } else { $null }
$wouldRaiseCurrent = $false

foreach ($gpu in $selected) {
    if ($hasPower) {
        $proposedPower = [double]$PowerLimitWatts
        if ($proposedPower -lt $gpu.MinimumPowerLimitWatts -or $proposedPower -gt $gpu.MaximumPowerLimitWatts) {
            $profileReasonCodes.Add('outside-vendor-power-range')
        }
        if ($proposedPower -gt ($gpu.DefaultPowerLimitWatts + 0.5)) { $profileReasonCodes.Add('above-vendor-default-power') }
        if ($proposedPower -gt ($gpu.CurrentPowerLimitWatts + 0.5)) {
            $wouldRaiseCurrent = $true
            if (-not $AcknowledgePowerIncrease) { $profileReasonCodes.Add('would-raise-current-power-limit') }
        }
    }
    if ($hasClock -and [double]$MaxGraphicsClockMHz -gt $gpu.MaximumGraphicsClockMHz) {
        $profileReasonCodes.Add('above-vendor-maximum-clock')
    }
}
if ($wouldRaiseCurrent -and $AcknowledgePowerIncrease) {
    $warnings.Add('The proposed profile raises at least one current power cap; explicit acknowledgement was supplied.')
}

$migration = [ordered]@{
    Status = 'NOT_INSPECTED'
    ApplyTask = $false
    ResetTask = $false
    ProtectedRollback = $false
    LastState = $null
    Action = 'Migration state was not inspected.'
}
if (-not $SkipMigrationInspection) {
    $applyTaskName = 'CA GPU Limits'
    $resetTaskName = 'CA GPU Limits Reset'
    $dataRoot = Join-Path $env:ProgramData 'CAGpuLimits'
    $statePath = Join-Path $dataRoot 'gpu-limits-state.json'
    $rollbackPath = Join-Path $dataRoot 'gpu-limits-backup.json'
    $applyTask = Get-ScheduledTask -TaskName $applyTaskName -ErrorAction SilentlyContinue
    $resetTask = Get-ScheduledTask -TaskName $resetTaskName -ErrorAction SilentlyContinue
    $migration.ApplyTask = $null -ne $applyTask
    $migration.ResetTask = $null -ne $resetTask
    $migration.ProtectedRollback = Test-Path -LiteralPath $rollbackPath -PathType Leaf
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try { $migration.LastState = [string](Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json).status }
        catch { $migration.LastState = 'unreadable' }
    }
    $legacyAction = $null -ne $applyTask -and [string]$applyTask.Actions.Execute -match 'powershell(?:\.exe)?$'
    if ($legacyAction -and $migration.LastState -eq 'applied' -and -not $migration.ProtectedRollback) {
        $migration.Status = 'LEGACY_RESET_REQUIRED'
        $migration.Action = 'Use the previously installed control panel to reset the legacy profile before installing the compiled helper.'
        $migrationReasonCodes.Add('legacy-reset-required')
    }
    elseif ($null -ne $applyTask -and [string]$applyTask.Actions.Execute -match 'CAGpuHelper(?:\.exe)?$') {
        $migration.Status = 'COMPILED_HELPER_INSTALLED'
        $migration.Action = 'An installed compiled profile exists; use its fixed Reset task before changing to a different profile.'
        if ($migration.ProtectedRollback) {
            try {
                $saved = Get-Content -Raw -LiteralPath $rollbackPath | ConvertFrom-Json
                $savedIndices = @($saved.targets | ForEach-Object { [int]$_.requestedIndex } | Sort-Object)
                $requestedIndices = @($indices | Sort-Object)
                $sameTargets = ($savedIndices -join ',') -eq ($requestedIndices -join ',')
                $samePower = $hasPower -and [Math]::Abs([double]$saved.powerLimitWatts - [double]$PowerLimitWatts) -le 0.5
                $sameClock = $hasClock -and [int]$saved.maxClockMHz -eq [int]$MaxGraphicsClockMHz
                if (($hasPower -or $hasClock) -and -not ($sameTargets -and $samePower -and $sameClock)) {
                    $migrationReasonCodes.Add('installed-profile-reset-required')
                }
            }
            catch { $migrationReasonCodes.Add('rollback-record-unreadable') }
        }
        elseif ($migration.LastState -eq 'applied') { $migrationReasonCodes.Add('rollback-record-missing') }
    }
    elseif ($null -eq $applyTask) {
        $migration.Status = 'FRESH_INSTALL'
        $migration.Action = 'No GPU limit task is installed.'
    }
    else {
        $migration.Status = 'LEGACY_OR_UNKNOWN'
        $migration.Action = 'Review the existing task before installation.'
    }
}

$profileReasons = @($profileReasonCodes | Select-Object -Unique)
$migrationReasons = @($migrationReasonCodes | Select-Object -Unique)
$reasons = @(@($profileReasons) + @($migrationReasons) | Select-Object -Unique)
$profileComplete = $hasPower -and $hasClock
$wouldPass = $profileComplete -and $reasons.Count -eq 0
$planStatus = if ($reasons.Count -gt 0) { 'REJECTED' } elseif (-not $profileComplete) { 'INVENTORY' } elseif ($source -eq 'fixture') { 'FIXTURE' } else { 'READY' }
if ($source -eq 'fixture') { $reasons = @('fixture-source') + $reasons }

[pscustomobject][ordered]@{
    SchemaVersion = 1
    GeneratedUtc = [DateTime]::UtcNow.ToString('o')
    Source = $source
    PlanStatus = $planStatus
    CanProceedToInstaller = $planStatus -eq 'READY'
    WouldPassSafetyChecks = $wouldPass
    ProfileChecksPass = $profileComplete -and $profileReasons.Count -eq 0
    MigrationChecksPass = $migrationReasons.Count -eq 0
    HardwareWrites = $false
    SelectedGpuCount = $selected.Count
    ProposedPowerLimitWatts = if ($hasPower) { [int]$PowerLimitWatts } else { $null }
    ProposedMaxGraphicsClockMHz = if ($hasClock) { [int]$MaxGraphicsClockMHz } else { $null }
    SuggestedSharedPowerStartingPointWatts = $suggestedSharedPower
    SuggestedClockMHz = $null
    WouldRaiseCurrentPowerLimit = $wouldRaiseCurrent
    ReasonCodes = @($reasons)
    ProfileReasonCodes = @($profileReasons)
    MigrationReasonCodes = @($migrationReasons)
    Warnings = @($warnings)
    Migration = [pscustomobject]$migration
    Gpus = @($selected)
}
