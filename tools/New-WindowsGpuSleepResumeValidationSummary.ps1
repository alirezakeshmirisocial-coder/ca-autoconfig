[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WindowsReportPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CollectionStartedUtc,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CollectionEndedUtc,

    [ValidateRange(0, 100)]
    [int]$ResumeEventCount = 0,

    [string]$SleepTimeUtc,

    [string]$WakeTimeUtc,

    [bool]$EventLogReadSucceeded = $true,

    [ValidateRange(1, 600)]
    [int]$MinimumPreSleepSeconds = 10,

    [ValidateRange(1, 600)]
    [int]$MinimumPostWakeSeconds = 10,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-UtcDateTime {
    param($Value, [string]$FieldName)
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    try {
        return [DateTime]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
    }
    catch { throw "$FieldName must be a valid date-time value." }
}

$resolvedReport = (Resolve-Path -LiteralPath $WindowsReportPath).Path
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if ([string]::Equals($resolvedOutput, $resolvedReport, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputPath must be different from WindowsReportPath.'
}
if ((Test-Path -LiteralPath $resolvedOutput) -and -not $Force) {
    throw "Output already exists: $resolvedOutput. Use -Force to replace it."
}

$report = Get-Content -Raw -LiteralPath $resolvedReport | ConvertFrom-Json
if ([int]$report.schemaVersion -ne 3 -or
    [string]$report.source -ne 'live-windows-polling-read-only' -or
    [string]$report.counterProvider -ne 'windows-pdh-raw-engine') {
    throw 'WindowsReportPath must be a schema-v3 live windows-pdh-raw-engine polling report.'
}
if ([bool]$report.canUseInHud -or [bool]$report.hardwareWrites -or
    [bool]$report.networkAccess -or [bool]$report.elevationRequested -or
    [bool]$report.rawAdapterIdentifiersIncluded) {
    throw 'The Windows report violates a read-only or privacy boundary.'
}

$completedCollections = [int]$report.completedCollections
$fullCollections = [int]$report.successfulMappingCollections
$partialCollections = [int]$report.partialMappingCollections
$unavailableCollections = [int]$report.unavailableCollections
$engineValidCollections = [int]$report.successfulEngineLoadCollections
$memoryValidCollections = [int]$report.successfulDedicatedMemoryCollections
$suppressedOverlaps = [int]$report.suppressedOverlaps
$collectionCounts = @(
    $fullCollections
    $partialCollections
    $unavailableCollections
    $engineValidCollections
    $memoryValidCollections
    $suppressedOverlaps
)
if ($completedCollections -le 0 -or
    @($collectionCounts | Where-Object { $_ -lt 0 }).Count -gt 0 -or
    ($fullCollections + $partialCollections + $unavailableCollections) -ne $completedCollections -or
    $engineValidCollections -gt $completedCollections -or
    $memoryValidCollections -gt $completedCollections) {
    throw 'The Windows report collection counters are inconsistent.'
}

$failureReasonProperty = $report.PSObject.Properties['failureReasonCounts']
$failureReasonCounts = if ($null -eq $failureReasonProperty) { @() } else { @($failureReasonProperty.Value) }
$hasReportedFailures = $false
foreach ($reason in $failureReasonCounts) {
    $codeProperty = $reason.PSObject.Properties['code']
    $countProperty = $reason.PSObject.Properties['count']
    if ($null -eq $codeProperty -or $null -eq $countProperty -or
        [string]$codeProperty.Value -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
        [int]$countProperty.Value -le 0) {
        throw 'The Windows report contains an invalid or unsafe failure-reason entry.'
    }
    $hasReportedFailures = $true
}
if ($hasReportedFailures -and ($partialCollections + $unavailableCollections) -eq 0) {
    throw 'The Windows report failure reasons disagree with its collection counters.'
}

$reportCapturedUtc = ConvertTo-UtcDateTime $report.capturedUtc 'report.capturedUtc'
$elapsedMilliseconds = [long]$report.elapsedMilliseconds
if ($elapsedMilliseconds -le 0) { throw 'The Windows report has no positive elapsed window.' }
$windowStart = ConvertTo-UtcDateTime $CollectionStartedUtc 'CollectionStartedUtc'
$windowEnd = ConvertTo-UtcDateTime $CollectionEndedUtc 'CollectionEndedUtc'
if ($windowEnd -le $windowStart) { throw 'The observed collection wall-clock window is not positive.' }
if ($reportCapturedUtc -lt $windowStart -or $reportCapturedUtc -gt $windowEnd.AddSeconds(5)) {
    throw 'The report capture time falls outside the observed collection wall-clock window.'
}

$sleepTime = $null
$wakeTime = $null
$eventTimestampsValid = $false
$eventWithinWindow = $false
$preSleepSeconds = $null
$sleepSeconds = $null
$postWakeSeconds = $null
if ($ResumeEventCount -eq 1 -and
    -not [string]::IsNullOrWhiteSpace($SleepTimeUtc) -and
    -not [string]::IsNullOrWhiteSpace($WakeTimeUtc)) {
    try {
        $sleepTime = ConvertTo-UtcDateTime $SleepTimeUtc 'SleepTimeUtc'
        $wakeTime = ConvertTo-UtcDateTime $WakeTimeUtc 'WakeTimeUtc'
        $eventTimestampsValid = $wakeTime -gt $sleepTime
    }
    catch {
        $eventTimestampsValid = $false
    }
    if ($eventTimestampsValid) {
        $eventWithinWindow = $sleepTime -ge $windowStart -and $wakeTime -le $windowEnd
        if ($eventWithinWindow) {
            $preSleepSeconds = ($sleepTime - $windowStart).TotalSeconds
            $sleepSeconds = ($wakeTime - $sleepTime).TotalSeconds
            $postWakeSeconds = ($windowEnd - $wakeTime).TotalSeconds
        }
    }
}

$reasonCodes = New-Object Collections.Generic.List[string]
$status = 'READY_FOR_MANUAL_SLEEP_RESUME_REVIEW'
if (-not $EventLogReadSucceeded) {
    $status = 'EVENT_SOURCE_UNAVAILABLE'
    $reasonCodes.Add('power-event-log-read-failed')
}
elseif ($ResumeEventCount -eq 0) {
    $status = 'NO_RESUME_OBSERVED'
    $reasonCodes.Add('no-new-resume-event')
}
elseif ($ResumeEventCount -ne 1) {
    $status = 'MULTIPLE_RESUMES_OBSERVED'
    $reasonCodes.Add('multiple-new-resume-events')
}
elseif (-not $eventTimestampsValid -or -not $eventWithinWindow) {
    $status = 'INVALID_RESUME_EVENT'
    $reasonCodes.Add('resume-event-invalid-or-outside-polling-window')
}
elseif ($preSleepSeconds -lt $MinimumPreSleepSeconds -or
    $postWakeSeconds -lt $MinimumPostWakeSeconds) {
    $status = 'INSUFFICIENT_PRE_OR_POST_WINDOW'
    $reasonCodes.Add('awake-observation-window-too-short')
}
elseif ($unavailableCollections -gt 0 -or $suppressedOverlaps -gt 0) {
    $status = 'WINDOWS_PROVIDER_UNAVAILABLE'
    $reasonCodes.Add('windows-provider-unavailable-or-overlapped')
}
elseif ($partialCollections -gt 0 -or
    $engineValidCollections -ne $completedCollections -or
    $memoryValidCollections -ne $completedCollections) {
    $status = 'WINDOWS_PROVIDER_PARTIAL'
    $reasonCodes.Add('windows-provider-retained-partial-evidence')
}
else {
    $reasonCodes.Add('manual-sleep-resume-review-required')
}

$summary = [pscustomobject][ordered]@{
    schemaVersion                  = 1
    createdUtc                     = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    scenario                       = 'manual-windows-sleep-resume'
    status                         = $status
    reasonCodes                    = $reasonCodes.ToArray()
    promotionAuthorized            = $false
    valuesCompared                 = $false
    manualReviewRequired           = $true
    thresholds                     = [pscustomobject][ordered]@{
        minimumPreSleepSeconds  = $MinimumPreSleepSeconds
        minimumPostWakeSeconds  = $MinimumPostWakeSeconds
    }
    pollingWindow                  = [pscustomobject][ordered]@{
        startUtc            = $windowStart.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        endUtc              = $windowEnd.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        wallClockSeconds    = [Math]::Round(($windowEnd - $windowStart).TotalSeconds, 3)
        reportElapsedSeconds = [Math]::Round($elapsedMilliseconds / 1000.0, 3)
        reportCapturedUtc   = $reportCapturedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        completed           = $completedCollections
        fullMappings        = $fullCollections
        partialMappings     = $partialCollections
        unavailable         = $unavailableCollections
        suppressed          = $suppressedOverlaps
        engineValid         = $engineValidCollections
        memoryValid         = $memoryValidCollections
        failureReasonCounts = @($failureReasonCounts)
    }
    powerEvent                     = [pscustomobject][ordered]@{
        provider               = 'Microsoft-Windows-Power-Troubleshooter'
        eventId                = 1
        eventLogReadSucceeded  = $EventLogReadSucceeded
        observedEventCount     = $ResumeEventCount
        timestampsValid        = $eventTimestampsValid
        withinPollingWindow    = $eventWithinWindow
        sleepTimeUtc           = if ($eventTimestampsValid -and $eventWithinWindow) { $sleepTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
        wakeTimeUtc            = if ($eventTimestampsValid -and $eventWithinWindow) { $wakeTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
        preSleepSeconds        = if ($null -eq $preSleepSeconds) { $null } else { [Math]::Round($preSleepSeconds, 3) }
        sleepSeconds           = if ($null -eq $sleepSeconds) { $null } else { [Math]::Round($sleepSeconds, 3) }
        postWakeSeconds        = if ($null -eq $postWakeSeconds) { $null } else { [Math]::Round($postWakeSeconds, 3) }
    }
    inputHashes                    = [pscustomobject][ordered]@{
        windowsReportSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedReport).Hash.ToLowerInvariant()
    }
    privacy                       = [pscustomobject][ordered]@{
        inputFilenameIncluded       = $false
        eventRecordIdIncluded       = $false
        computerNameIncluded        = $false
        userIdentityIncluded        = $false
        wakeSourceIncluded          = $false
        rawEventXmlIncluded         = $false
        rawAdapterIdentifiersIncluded = $false
    }
    analysisHardwareWrites         = $false
    analysisNetworkAccess          = $false
    analysisElevationRequested     = $false
    canUseInHud                    = $false
}

$outputDirectory = Split-Path -Parent $resolvedOutput
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$temporaryOutput = Join-Path $outputDirectory ('.ca-sleep-resume-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    $json = $summary | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($temporaryOutput, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryOutput -Destination $resolvedOutput -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryOutput) {
        Remove-Item -LiteralPath $temporaryOutput -Force
    }
}

[pscustomobject]@{
    Status                 = $status
    OutputPath             = $resolvedOutput
    ResumeEventCount       = $ResumeEventCount
    EventWithinWindow      = $eventWithinWindow
    PreSleepSeconds        = if ($null -eq $preSleepSeconds) { $null } else { [Math]::Round($preSleepSeconds, 3) }
    PostWakeSeconds        = if ($null -eq $postWakeSeconds) { $null } else { [Math]::Round($postWakeSeconds, 3) }
    ValuesCompared         = $false
    PromotionAuthorized    = $false
    CanUseInHud            = $false
}
