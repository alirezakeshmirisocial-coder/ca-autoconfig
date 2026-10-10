[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$Last = 12,

    [string]$LabPathOverride,

    [ValidateSet('SFace', 'LBPH')]
    [string]$Engine = 'SFace',

    [switch]$IncludeHistory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$labPath = if ($LabPathOverride) {
    $LabPathOverride
}
else {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuardLab'
}
$eventPath = Join-Path $labPath $(if ($Engine -eq 'SFace') { 'presence-events-sface-adaptive.jsonl' } else { 'presence-events.jsonl' })
$profilePath = Join-Path $labPath $(if ($Engine -eq 'SFace') { 'sface-profile.json' } else { 'presence-profile.json' })
$statePath = Join-Path $labPath 'durable-run-state.json'
$runConfigPath = Join-Path $labPath 'durable-run.json'
if (-not (Test-Path -LiteralPath $eventPath -PathType Leaf)) {
    throw 'No Presence Lab results exist yet. Run Start-PresenceTest.ps1 and let at least one scan finish.'
}

$events = @(Get-Content -LiteralPath $eventPath | ForEach-Object {
    try { $_ | ConvertFrom-Json } catch { $null }
} | Where-Object { $null -ne $_ })
if (-not $IncludeHistory -and (Test-Path -LiteralPath $runConfigPath -PathType Leaf)) {
    $runConfig = Get-Content -Raw -LiteralPath $runConfigPath | ConvertFrom-Json
    if ([string]$runConfig.Engine -eq $Engine) {
        $runStart = [DateTimeOffset]::Parse([string]$runConfig.StartUtc)
        $events = @($events | Where-Object {
            [DateTimeOffset]::Parse([string]$_.timestampUtc) -ge $runStart
        })
    }
}
if ($events.Count -eq 0) {
    throw 'The Presence Lab log contains no readable scan results.'
}

$scopeText = if ($IncludeHistory) { 'all history' } else { 'current durable run' }
Write-Host "Presence Lab summary ($scopeText):" -ForegroundColor Cyan
$events |
    Group-Object -Property status |
    Sort-Object -Property Name |
    Select-Object @{ Name = 'Status'; Expression = { $_.Name } }, Count,
        @{ Name = 'Percent'; Expression = { [Math]::Round(100 * $_.Count / $events.Count, 1) } } |
    Format-Table -AutoSize

$scores = if ($Engine -eq 'SFace') {
    @($events | ForEach-Object {
        if ($null -ne $_.PSObject.Properties['medianSimilarity'] -and $null -ne $_.medianSimilarity) {
            [double]$_.medianSimilarity
        }
        elseif ($null -ne $_.PSObject.Properties['similarity'] -and $null -ne $_.similarity) {
            [double]$_.similarity
        }
    })
}
else {
    @($events | Where-Object { $null -ne $_.medianScore } | ForEach-Object { [double]$_.medianScore })
}
if ($scores.Count -gt 0) {
    [pscustomobject]@{
        TotalScans         = $events.Count
        FirstScanUtc       = $events[0].timestampUtc
        LastScanUtc        = $events[-1].timestampUtc
        ScoreMetric        = $(if ($Engine -eq 'SFace') { 'cosine similarity' } else { 'medianScore' })
        MinimumMedianScore = [Math]::Round(($scores | Measure-Object -Minimum).Minimum, 4)
        AverageMedianScore = [Math]::Round(($scores | Measure-Object -Average).Average, 4)
        MaximumMedianScore = [Math]::Round(($scores | Measure-Object -Maximum).Maximum, 4)
    } | Format-List
}

if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
    Write-Host 'Saved profile:' -ForegroundColor Cyan
    Get-Content -Raw -LiteralPath $profilePath | ConvertFrom-Json |
        Select-Object savedUtc, engine, cameraIndex, threshold, intervalSeconds, scanSeconds,
            baselineSeconds, cautiousSeconds, warningAfterSeconds, burstIntervalSeconds,
            burstSamples, openCvThreads, minimumQualityFrames, requiredMatches |
        Format-List
}

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    Write-Host 'Durable run state:' -ForegroundColor Cyan
    Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json | Format-List
}

Write-Host "Last $Last scans:" -ForegroundColor Cyan
$events | Select-Object -Last $Last |
    Select-Object timestampUtc, status, mode, sampleKind, threshold, similarity,
        attempts, qualityFrames, matches, matchRatio, medianScore, medianSimilarity |
    Format-Table -AutoSize
