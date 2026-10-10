[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WindowsReportPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkloadRunPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [ValidateRange(1, 100)]
    [int]$MinimumLoadedUtilizationPercent = 50,

    [ValidateRange(1, 100)]
    [int]$MinimumLoadedSamplePercent = 50,

    [ValidateRange(1, 3600)]
    [int]$MinimumOverlapSeconds = 10,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\benchmark\PowerCurve.psm1') -Force

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

$resolvedWindows = (Resolve-Path -LiteralPath $WindowsReportPath).Path
$resolvedWorkload = (Resolve-Path -LiteralPath $WorkloadRunPath).Path
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if ([string]::Equals($resolvedOutput, $resolvedWindows, [StringComparison]::OrdinalIgnoreCase) -or
    [string]::Equals($resolvedOutput, $resolvedWorkload, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputPath must be different from both evidence input files.'
}
$outputExists = Test-Path -LiteralPath $resolvedOutput
if ($outputExists -and -not $Force) {
    throw "Output already exists: $resolvedOutput. Use -Force to replace it."
}

$windowsText = Get-Content -Raw -LiteralPath $resolvedWindows
$workloadText = Get-Content -Raw -LiteralPath $resolvedWorkload
$windows = $windowsText | ConvertFrom-Json
$workload = $workloadText | ConvertFrom-Json

if ([int]$windows.schemaVersion -ne 3 -or
    [string]$windows.source -ne 'live-windows-polling-read-only' -or
    [string]$windows.counterProvider -ne 'windows-pdh-raw-engine') {
    throw 'WindowsReportPath must be a schema-v3 live windows-pdh-raw-engine polling report.'
}
if ([bool]$windows.canUseInHud -or [bool]$windows.hardwareWrites -or
    [bool]$windows.networkAccess -or [bool]$windows.elevationRequested -or
    [bool]$windows.rawAdapterIdentifiersIncluded) {
    throw 'The Windows report violates a read-only or privacy boundary.'
}
$completedCollections = [int]$windows.completedCollections
$fullCollections = [int]$windows.successfulMappingCollections
$partialCollections = [int]$windows.partialMappingCollections
$unavailableCollections = [int]$windows.unavailableCollections
$engineValidCollections = [int]$windows.successfulEngineLoadCollections
$memoryValidCollections = [int]$windows.successfulDedicatedMemoryCollections
$suppressedOverlaps = [int]$windows.suppressedOverlaps
if ($completedCollections -le 0 -or
    @($fullCollections, $partialCollections, $unavailableCollections, $engineValidCollections, $memoryValidCollections, $suppressedOverlaps |
        Where-Object { $_ -lt 0 }).Count -gt 0 -or
    ($fullCollections + $partialCollections + $unavailableCollections) -ne $completedCollections -or
    $engineValidCollections -gt $completedCollections -or
    $memoryValidCollections -gt $completedCollections) {
    throw 'The Windows report collection counters are inconsistent.'
}
$failureReasonProperty = $windows.PSObject.Properties['failureReasonCounts']
$windowsFailureReasonCounts = if ($null -eq $failureReasonProperty) { @() } else { @($failureReasonProperty.Value) }
$hasReportedFailures = $false
foreach ($reason in $windowsFailureReasonCounts) {
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

Assert-CAPowerCurveRun -Run $workload | Out-Null
$privacy = $workload.privacy
if ([bool]$privacy.containsGpuUuid -or [bool]$privacy.containsMachineName -or
    [bool]$privacy.containsUserName -or [bool]$privacy.containsPaths -or
    [bool]$privacy.containsRawCommand) {
    throw 'The workload run violates the schema-v3 privacy boundary.'
}

$windowsEnd = ConvertTo-UtcDateTime $windows.capturedUtc 'windows.capturedUtc'
$windowsElapsedMilliseconds = [long]$windows.elapsedMilliseconds
if ($windowsElapsedMilliseconds -le 0) { throw 'The Windows report has no positive elapsed window.' }
$windowsStart = $windowsEnd.AddMilliseconds(-$windowsElapsedMilliseconds)

$startedProperty = $workload.measurement.PSObject.Properties['startedUtc']
$endedProperty = $workload.measurement.PSObject.Properties['endedUtc']
if ($null -eq $startedProperty -or $null -eq $endedProperty) {
    throw 'The workload run needs explicit measurement.startedUtc and measurement.endedUtc values for time alignment.'
}
$workloadStart = ConvertTo-UtcDateTime $startedProperty.Value 'workload.measurement.startedUtc'
$workloadEnd = ConvertTo-UtcDateTime $endedProperty.Value 'workload.measurement.endedUtc'
$workloadWindowSeconds = ($workloadEnd - $workloadStart).TotalSeconds
if ($workloadWindowSeconds -le 0) { throw 'The workload measurement window is not positive.' }
$workloadSeconds = [int]$workload.protocol.sampleSeconds
if ($workloadSeconds -le 0) { throw 'The workload run has no positive sample window.' }
$windowToleranceSeconds = [Math]::Max(2.0, ([int]$workload.protocol.intervalMilliseconds / 1000.0) + 1.0)
if ([Math]::Abs($workloadWindowSeconds - $workloadSeconds) -gt $windowToleranceSeconds) {
    throw 'The explicit workload measurement window disagrees with protocol.sampleSeconds.'
}

$overlapStart = if ($windowsStart -gt $workloadStart) { $windowsStart } else { $workloadStart }
$overlapEnd = if ($windowsEnd -lt $workloadEnd) { $windowsEnd } else { $workloadEnd }
$overlapSeconds = [Math]::Max(0.0, ($overlapEnd - $overlapStart).TotalSeconds)
$coveragePercent = [Math]::Min(100.0, 100.0 * $overlapSeconds / $workloadWindowSeconds)

$gpuLoad = @()
foreach ($gpu in @($workload.gpus)) {
    $samples = @($gpu.samples)
    $validLoads = @($samples | ForEach-Object {
        if ($null -ne $_.utilizationPercent) { [double]$_.utilizationPercent }
    })
    $loadedLoads = @($validLoads | Where-Object { $_ -ge $MinimumLoadedUtilizationPercent })
    $validCoveragePercent = if ($samples.Count -eq 0) { 0.0 } else { 100.0 * $validLoads.Count / $samples.Count }
    $loadedSamplePercent = if ($validLoads.Count -eq 0) { 0.0 } else { 100.0 * $loadedLoads.Count / $validLoads.Count }
    if ($validLoads.Count -eq 0) {
        $maximum = $null
    }
    else {
        $maximum = [double](($validLoads | Measure-Object -Maximum).Maximum)
    }
    $gpuLoad += [pscustomobject][ordered]@{
        index                     = [int]$gpu.index
        sampleCount               = $samples.Count
        validUtilizationSamples   = $validLoads.Count
        loadedUtilizationSamples  = $loadedLoads.Count
        validSampleCoveragePercent = [Math]::Round($validCoveragePercent, 3)
        loadedSamplePercent       = [Math]::Round($loadedSamplePercent, 3)
        maximumUtilizationPercent = if ($null -eq $maximum) { $null } else { [Math]::Round($maximum, 3) }
        reachedLoadedThreshold    = $samples.Count -gt 0 -and
            $validLoads.Count -eq $samples.Count -and
            $loadedSamplePercent -ge $MinimumLoadedSamplePercent
    }
}
$allWorkloadGpusLoaded = $gpuLoad.Count -gt 0 -and
    @($gpuLoad | Where-Object { -not $_.reachedLoadedThreshold }).Count -eq 0

$reasonCodes = New-Object Collections.Generic.List[string]
$status = 'READY_FOR_MANUAL_VALUE_COMPARISON'
if ([string]$workload.source -ne 'live') {
    $status = 'FIXTURE_ONLY'
    $reasonCodes.Add('workload-source-not-live')
}
elseif ([string]$workload.result.status -ne 'passed') {
    $status = 'WORKLOAD_FAILED'
    $reasonCodes.Add('workload-result-not-passed')
}
elseif ($overlapSeconds -lt $MinimumOverlapSeconds -or $coveragePercent -lt 95.0) {
    $status = 'INSUFFICIENT_WINDOW_OVERLAP'
    $reasonCodes.Add('measurement-windows-not-aligned')
}
elseif (-not $allWorkloadGpusLoaded) {
    $status = 'WORKLOAD_NOT_FULLY_LOADED'
    $reasonCodes.Add('loaded-utilization-threshold-not-met')
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
    $reasonCodes.Add('manual-value-comparison-required')
}

$windowsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedWindows).Hash.ToLowerInvariant()
$workloadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedWorkload).Hash.ToLowerInvariant()
$summary = [pscustomobject][ordered]@{
    schemaVersion                 = 1
    createdUtc                    = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    status                        = $status
    reasonCodes                   = $reasonCodes.ToArray()
    promotionAuthorized           = $false
    valuesCompared                = $false
    manualValueComparisonRequired = $true
    thresholds                    = [pscustomobject][ordered]@{
        minimumLoadedUtilizationPercent = $MinimumLoadedUtilizationPercent
        minimumLoadedSamplePercent      = $MinimumLoadedSamplePercent
        minimumOverlapSeconds            = $MinimumOverlapSeconds
        minimumCoveragePercent           = 95
    }
    windowsWindow                 = [pscustomobject][ordered]@{
        startUtc         = $windowsStart.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        endUtc           = $windowsEnd.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        elapsedSeconds   = [Math]::Round($windowsElapsedMilliseconds / 1000.0, 3)
        completed        = $completedCollections
        fullMappings     = $fullCollections
        partialMappings  = $partialCollections
        unavailable      = $unavailableCollections
        suppressed       = $suppressedOverlaps
        engineValid      = $engineValidCollections
        memoryValid      = $memoryValidCollections
        failureReasonCounts = @($windowsFailureReasonCounts)
    }
    workloadWindow                = [pscustomobject][ordered]@{
        startUtc        = $workloadStart.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        endUtc          = $workloadEnd.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        sampleSeconds   = $workloadSeconds
        measuredSeconds = [Math]::Round($workloadWindowSeconds, 3)
        sourceIsLive    = [string]$workload.source -eq 'live'
        resultStatus    = [string]$workload.result.status
        gpuLoad         = @($gpuLoad)
    }
    overlap                       = [pscustomobject][ordered]@{
        seconds         = [Math]::Round($overlapSeconds, 3)
        coveragePercent = [Math]::Round($coveragePercent, 3)
    }
    inputHashes                   = [pscustomobject][ordered]@{
        windowsReportSha256 = $windowsHash
        workloadRunSha256   = $workloadHash
    }
    privacy                      = [pscustomobject][ordered]@{
        inputFilenamesIncluded = $false
        workloadIdentityIncluded = $false
        rawAdapterIdentifiersIncluded = $false
    }
    analysisHardwareWrites       = $false
    analysisNetworkAccess        = $false
    analysisElevationRequested   = $false
    canUseInHud                  = $false
}

$outputDirectory = Split-Path -Parent $resolvedOutput
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$json = $summary | ConvertTo-Json -Depth 10
$temporaryOutput = Join-Path $outputDirectory ('.ca-loaded-validation-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($temporaryOutput, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryOutput -Destination $resolvedOutput -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryOutput) {
        Remove-Item -LiteralPath $temporaryOutput -Force
    }
}

[pscustomobject]@{
    Status                         = $status
    OutputPath                     = $resolvedOutput
    OverlapSeconds                 = [Math]::Round($overlapSeconds, 3)
    CoveragePercent                = [Math]::Round($coveragePercent, 3)
    AllWorkloadGpusLoaded          = $allWorkloadGpusLoaded
    ValuesCompared                 = $false
    ManualValueComparisonRequired  = $true
    PromotionAuthorized            = $false
    CanUseInHud                    = $false
}
