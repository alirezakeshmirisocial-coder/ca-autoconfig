$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'tools\Test-WindowsGpuEvidenceBundle.ps1'
$sourceReport = Join-Path $root 'docs\evidence\windows-gpu-pdh-raw-no-resume-control-120s-2026-10-10.json'
$sourceSummary = Join-Path $root 'docs\evidence\windows-gpu-pdh-raw-no-resume-control-summary-120s-2026-10-10.json'
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ca-evidence-bundle-tests-' + [Guid]::NewGuid().ToString('N'))))
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($temporaryRoot) -notlike 'ca-evidence-bundle-tests-*') {
    throw 'Unsafe temporary test path.'
}
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Json {
    param($Value, [string]$Path)
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action }
    catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

try {
    $reportOnly = & $tool -ReportPath $sourceReport
    Assert-True ([bool]$reportOnly.SafeToAttach -and
        $null -eq $reportOnly.SummarySha256 -and
        [int]$reportOnly.CompletedCollections -eq 61 -and
        -not [bool]$reportOnly.CanUseInHud) 'A safe standalone report did not pass preflight.'
    Write-Output 'PASS a sanitized standalone report is attachable without being authorized'

    $linked = & $tool -ReportPath $sourceReport -SummaryPath $sourceSummary
    Assert-True ([bool]$linked.SafeToAttach -and
        [string]$linked.SummaryType -eq 'sleep-resume-link' -and
        [string]$linked.EvidenceStatus -eq 'NO_RESUME_OBSERVED') 'A valid linked negative control was not preserved.'
    Write-Output 'PASS a linked negative result remains useful attachable evidence'

    $report = Get-Content -Raw -LiteralPath $sourceReport | ConvertFrom-Json
    $summary = Get-Content -Raw -LiteralPath $sourceSummary | ConvertFrom-Json

    $unsafeReport = $report | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $unsafeReport.hardwareWrites = $true
    $unsafeReportPath = Join-Path $temporaryRoot 'unsafe-report.json'
    Write-Json $unsafeReport $unsafeReportPath
    Assert-Throws { & $tool -ReportPath $unsafeReportPath | Out-Null } 'A report declaring hardware writes passed preflight.'
    Write-Output 'PASS unsafe read-only flags are rejected'

    $badCounts = $report | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $badCounts.partialMappingCollections = 1
    $badCountsPath = Join-Path $temporaryRoot 'bad-counts.json'
    Write-Json $badCounts $badCountsPath
    Assert-Throws { & $tool -ReportPath $badCountsPath | Out-Null } 'Inconsistent collection counts passed preflight.'
    Write-Output 'PASS inconsistent collection counts are rejected'

    $unsafeReason = $report | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $unsafeReason.successfulMappingCollections = 60
    $unsafeReason.partialMappingCollections = 1
    $unsafeReason.successfulEngineLoadCollections = 60
    $unsafeReason.failureReasonCounts = @([pscustomobject]@{ code = 'C:\Users\Private\counter'; count = 1 })
    $unsafeReasonPath = Join-Path $temporaryRoot 'unsafe-reason.json'
    Write-Json $unsafeReason $unsafeReasonPath
    Assert-Throws { & $tool -ReportPath $unsafeReasonPath | Out-Null } 'An unsafe failure reason passed preflight.'
    Write-Output 'PASS unsafe failure text is rejected before attachment'

    $wrongSummary = $summary | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $wrongSummary.inputHashes.windowsReportSha256 = ('0' * 64)
    $wrongSummaryPath = Join-Path $temporaryRoot 'wrong-link-summary.json'
    Write-Json $wrongSummary $wrongSummaryPath
    Assert-Throws { & $tool -ReportPath $sourceReport -SummaryPath $wrongSummaryPath | Out-Null } 'A mismatched summary hash passed preflight.'
    Write-Output 'PASS a summary must hash-link to the exact report bytes'

    $privateSummary = $summary | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $privateSummary | Add-Member -NotePropertyName profilePath -NotePropertyValue 'C:\Users\Private\profile'
    $privateSummaryPath = Join-Path $temporaryRoot 'private-summary.json'
    Write-Json $privateSummary $privateSummaryPath
    Assert-Throws { & $tool -ReportPath $sourceReport -SummaryPath $privateSummaryPath | Out-Null } 'A private path field passed preflight.'
    $rawIdentityReport = $report | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $rawIdentityReport.adapters[0].name = 'pid_123_luid_0x00000000'
    $rawIdentityPath = Join-Path $temporaryRoot 'raw-identity-report.json'
    Write-Json $rawIdentityReport $rawIdentityPath
    Assert-Throws { & $tool -ReportPath $rawIdentityPath | Out-Null } 'A raw PID/LUID-like value passed preflight.'
    Write-Output 'PASS forbidden identity, identifier, and path values are rejected'

    $loadedSummary = [pscustomobject][ordered]@{
        schemaVersion = 1
        status = 'WORKLOAD_NOT_FULLY_LOADED'
        promotionAuthorized = $false
        valuesCompared = $false
        canUseInHud = $false
        workloadWindow = [pscustomobject]@{ sourceIsLive = $true }
        inputHashes = [pscustomobject]@{ windowsReportSha256 = $reportOnly.ReportSha256 }
        analysisHardwareWrites = $false
        analysisNetworkAccess = $false
        analysisElevationRequested = $false
    }
    $loadedSummaryPath = Join-Path $temporaryRoot 'loaded-summary.json'
    Write-Json $loadedSummary $loadedSummaryPath
    $loaded = & $tool -ReportPath $sourceReport -SummaryPath $loadedSummaryPath
    Assert-True ([string]$loaded.SummaryType -eq 'loaded-workload-link' -and
        [string]$loaded.EvidenceStatus -eq 'WORKLOAD_NOT_FULLY_LOADED') 'A safe loaded-workload failure was not retained.'
    Write-Output 'PASS loaded-workload failures remain attachable when hash-linked and private-data-free'

    $churnSummary = [pscustomobject][ordered]@{
        schemaVersion = 1
        scenario = 'deliberate-gpu-process-start-stop-churn'
        status = 'CHURN_NOT_PROVEN'
        pollingReportSha256 = $reportOnly.ReportSha256
        canUseInHud = $false
        hardwareWrites = $false
        networkAccess = $false
        elevationRequested = $false
        rawAdapterIdentifiersIncluded = $false
    }
    $churnSummaryPath = Join-Path $temporaryRoot 'churn-summary.json'
    Write-Json $churnSummary $churnSummaryPath
    $churn = & $tool -ReportPath $sourceReport -SummaryPath $churnSummaryPath
    Assert-True ([string]$churn.SummaryType -eq 'process-churn-link' -and
        [string]$churn.EvidenceStatus -eq 'CHURN_NOT_PROVEN') 'A safe process-churn failure was not retained.'
    Write-Output 'PASS process-churn failures remain attachable when hash-linked and private-data-free'

    Write-Output '9 Windows GPU evidence-preflight tests passed. Fixtures performed no network, event-log, hardware, or GPU-setting access.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $temporaryRoot).Path)
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notlike 'ca-evidence-bundle-tests-*') {
            throw 'Refusing unsafe temporary test cleanup.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
