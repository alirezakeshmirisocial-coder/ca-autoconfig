[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ReportPath,

    [string]$SummaryPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-SafeObject {
    param($Value, [string]$ObjectName)

    $forbiddenFields = @(
        'luid', 'pid', 'pnpId', 'pciBusId', 'uuid', 'gpuUuid',
        'machineName', 'userName', 'computerName', 'rawCommand', 'command',
        'prompt', 'workflow', 'eventRecordId', 'wakeSource', 'rawEventXml',
        'inputFilename', 'pollingReportFile', 'profilePath', 'browserPath'
    )
    $falseOnlyFields = @(
        'canUseInHud', 'hardwareWrites', 'networkAccess', 'elevationRequested',
        'rawAdapterIdentifiersIncluded', 'promotionAuthorized', 'valuesCompared',
        'analysisHardwareWrites', 'analysisNetworkAccess', 'analysisElevationRequested',
        'fixtureHardwareWrites', 'fixtureElevationRequested'
    )

    function Visit-Value {
        param($Current, [string]$Path)
        if ($null -eq $Current) { return }
        if ($Current -is [string]) {
            if ([string]$Current -match '(?i)(?:^[A-Z]:\\|\\Users\\|/home/|/Users/|<Event\b|\bluid[_:= -]|\bpid[_:= -]?\d+|\b(?:pnp|pci)[_:=\\]|\bGPU-[0-9a-f-]{16,}|S-1-\d)') {
                throw "$ObjectName contains a path, raw event, or raw identifier value at $Path."
            }
            return
        }
        if ($Current -is [ValueType]) { return }
        if ($Current -is [System.Collections.IDictionary]) {
            foreach ($key in @($Current.Keys)) {
                $name = [string]$key
                if ($name -in $forbiddenFields) { throw "$ObjectName contains forbidden field '$name'." }
                if ($name -in $falseOnlyFields -and [bool]$Current[$key]) {
                    throw "$ObjectName declares unsafe field '$name'."
                }
                Visit-Value $Current[$key] "$Path.$name"
            }
            return
        }
        if ($Current -is [System.Collections.IEnumerable] -and $Current -isnot [pscustomobject]) {
            $index = 0
            foreach ($item in $Current) {
                Visit-Value $item "$Path[$index]"
                $index++
            }
            return
        }
        foreach ($property in @($Current.PSObject.Properties)) {
            $name = [string]$property.Name
            if ($name -in $forbiddenFields) { throw "$ObjectName contains forbidden field '$name'." }
            if ($name -in $falseOnlyFields -and [bool]$property.Value) {
                throw "$ObjectName declares unsafe field '$name'."
            }
            Visit-Value $property.Value "$Path.$name"
        }
    }

    Visit-Value $Value $ObjectName
}

function Get-SafeFailureReasons {
    param($Report)
    $property = $Report.PSObject.Properties['failureReasonCounts']
    $reasons = if ($null -eq $property) { @() } else { @($property.Value) }
    foreach ($reason in $reasons) {
        $codeProperty = $reason.PSObject.Properties['code']
        $countProperty = $reason.PSObject.Properties['count']
        if ($null -eq $codeProperty -or $null -eq $countProperty -or
            [string]$codeProperty.Value -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
            [int]$countProperty.Value -le 0) {
            throw 'The report contains an invalid or unsafe failure-reason entry.'
        }
    }
    @($reasons)
}

$resolvedReport = (Resolve-Path -LiteralPath $ReportPath).Path
$report = Get-Content -Raw -LiteralPath $resolvedReport | ConvertFrom-Json
if ([int]$report.schemaVersion -ne 3 -or
    [string]$report.source -ne 'live-windows-polling-read-only' -or
    [string]$report.counterProvider -notin @('windows-wmi-formatted', 'windows-pdh', 'windows-pdh-raw-engine')) {
    throw 'ReportPath must be a schema-v3 live Windows GPU polling report with an explicit supported provider.'
}
Assert-SafeObject $report 'report'

$completed = [int]$report.completedCollections
$full = [int]$report.successfulMappingCollections
$partial = [int]$report.partialMappingCollections
$unavailable = [int]$report.unavailableCollections
$engineValid = [int]$report.successfulEngineLoadCollections
$memoryValid = [int]$report.successfulDedicatedMemoryCollections
$suppressed = [int]$report.suppressedOverlaps
$counts = @($full, $partial, $unavailable, $engineValid, $memoryValid, $suppressed)
if ($completed -le 0 -or @($counts | Where-Object { $_ -lt 0 }).Count -gt 0 -or
    ($full + $partial + $unavailable) -ne $completed -or
    $engineValid -gt $completed -or $memoryValid -gt $completed) {
    throw 'The report collection counters are inconsistent.'
}
$failureReasons = @(Get-SafeFailureReasons $report)
if ($failureReasons.Count -gt 0 -and ($partial + $unavailable) -eq 0) {
    throw 'The report failure reasons disagree with its collection counters.'
}

$reportHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedReport).Hash.ToLowerInvariant()
$summary = $null
$summaryHash = $null
$summaryType = $null
$evidenceStatus = [string]$report.finalStatus
if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
    $resolvedSummary = (Resolve-Path -LiteralPath $SummaryPath).Path
    if ([string]::Equals($resolvedSummary, $resolvedReport, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SummaryPath must be different from ReportPath.'
    }
    $summary = Get-Content -Raw -LiteralPath $resolvedSummary | ConvertFrom-Json
    Assert-SafeObject $summary 'summary'
    $summaryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedSummary).Hash.ToLowerInvariant()

    $linkedHash = $null
    if ($null -ne $summary.PSObject.Properties['inputHashes'] -and
        $null -ne $summary.inputHashes.PSObject.Properties['windowsReportSha256']) {
        $linkedHash = [string]$summary.inputHashes.windowsReportSha256
        $summaryType = if ($null -ne $summary.PSObject.Properties['workloadWindow']) {
            'loaded-workload-link'
        }
        elseif ([string]$summary.scenario -eq 'manual-windows-sleep-resume') {
            'sleep-resume-link'
        }
        else {
            'hash-linked-summary'
        }
    }
    elseif ($null -ne $summary.PSObject.Properties['pollingReportSha256']) {
        $linkedHash = [string]$summary.pollingReportSha256
        $summaryType = if ([string]$summary.scenario -eq 'deliberate-gpu-process-start-stop-churn') {
            'process-churn-link'
        }
        else {
            'hash-linked-summary'
        }
    }
    else {
        throw 'SummaryPath does not declare a supported polling-report hash link.'
    }
    if (-not [string]::Equals($linkedHash, $reportHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SummaryPath does not hash-link to the supplied report bytes.'
    }
    $evidenceStatus = [string]$summary.status
}

[pscustomobject][ordered]@{
    SafeToAttach               = $true
    ReportSha256               = $reportHash
    SummarySha256              = $summaryHash
    SummaryType                = $summaryType
    EvidenceStatus             = $evidenceStatus
    CounterProvider            = [string]$report.counterProvider
    CompletedCollections       = $completed
    FullMappings               = $full
    PartialMappings            = $partial
    UnavailableCollections     = $unavailable
    EngineValidCollections     = $engineValid
    MemoryValidCollections     = $memoryValid
    SuppressedOverlaps         = $suppressed
    FailureReasonEntryCount    = $failureReasons.Count
    FailuresRetained           = ($partial + $unavailable) -gt 0 -or $failureReasons.Count -gt 0
    PromotionAuthorized        = $false
    CanUseInHud                = $false
    HardwareWrites             = $false
    NetworkAccess              = $false
    ElevationRequested         = $false
    RawAdapterIdentifiers      = $false
}
