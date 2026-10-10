[CmdletBinding()]
param(
    [ValidateRange(20, 600)]
    [int]$DurationSeconds = 120,

    [ValidateRange(1, 10)]
    [int]$IntervalSeconds = 2,

    [string]$ResultPath,

    [string]$FixturePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-InvalidEvidence {
    param([Parameter(Mandatory = $true)][string]$Reason)
    throw "HUD overhead measurement failed: $Reason"
}

function Assert-ExactProperties {
    param($Object, [string[]]$Allowed, [string]$Scope)
    $actual = @($Object.PSObject.Properties.Name)
    foreach ($name in $actual) {
        if ($Allowed -notcontains $name) { Stop-InvalidEvidence "$Scope contains an unsupported field" }
    }
    foreach ($name in $Allowed) {
        if ($actual -notcontains $name) { Stop-InvalidEvidence "$Scope is missing a required field" }
    }
}

function Get-NearestRankPercentile {
    param([double[]]$Values, [double]$Percentile)
    if ($Values.Count -eq 0) { return 0.0 }
    $sorted = @($Values | Sort-Object)
    $rank = [Math]::Ceiling(($Percentile / 100.0) * $sorted.Count)
    $index = [Math]::Max(0, [Math]::Min($sorted.Count - 1, $rank - 1))
    return [double]$sorted[$index]
}

function Test-FiniteNumber {
    param([double]$Value)
    return -not [Double]::IsNaN($Value) -and -not [Double]::IsInfinity($Value)
}

function New-Summary {
    param(
        [object[]]$RawSamples,
        [int]$ProcessorCount,
        [bool]$MeasuredLive,
        [string]$AppVersion,
        [DateTime]$StartedUtc,
        [DateTime]$FinishedUtc
    )

    if ($ProcessorCount -lt 1 -or $ProcessorCount -gt 4096) { Stop-InvalidEvidence 'processor count is outside the accepted boundary' }
    if ($RawSamples.Count -lt 3) { Stop-InvalidEvidence 'at least three raw samples are required' }

    $intervals = @()
    for ($index = 1; $index -lt $RawSamples.Count; $index++) {
        $previous = $RawSamples[$index - 1]
        $current = $RawSamples[$index]
        foreach ($sample in @($previous, $current)) {
            Assert-ExactProperties $sample @('elapsedSeconds', 'cpuSeconds', 'workingSetBytes', 'privateBytes', 'responding') 'sample'
            if (-not (Test-FiniteNumber ([double]$sample.elapsedSeconds)) -or
                -not (Test-FiniteNumber ([double]$sample.cpuSeconds)) -or
                [double]$sample.elapsedSeconds -lt 0 -or [double]$sample.cpuSeconds -lt 0 -or
                [int64]$sample.workingSetBytes -lt 0 -or [int64]$sample.privateBytes -lt 0) {
                Stop-InvalidEvidence 'sample contains a non-finite or negative value'
            }
        }
        $elapsedDelta = [double]$current.elapsedSeconds - [double]$previous.elapsedSeconds
        $cpuDelta = [double]$current.cpuSeconds - [double]$previous.cpuSeconds
        if ($elapsedDelta -le 0 -or $cpuDelta -lt 0) { Stop-InvalidEvidence 'sample timing or cumulative CPU is not monotonic' }
        $normalizedCpu = 100.0 * $cpuDelta / $elapsedDelta / $ProcessorCount
        if (-not (Test-FiniteNumber $normalizedCpu) -or $normalizedCpu -lt 0 -or $normalizedCpu -gt 100.5) {
            Stop-InvalidEvidence 'normalized CPU is outside the accepted boundary'
        }
        $intervals += [pscustomobject][ordered]@{
            RelativeSeconds = [Math]::Round([double]$current.elapsedSeconds, 3)
            NormalizedCpuPercent = [Math]::Round($normalizedCpu, 4)
            WorkingSetMiB = [Math]::Round([double]$current.workingSetBytes / 1MB, 3)
            PrivateMemoryMiB = [Math]::Round([double]$current.privateBytes / 1MB, 3)
            Responding = [bool]$current.responding
        }
    }

    $cpuValues = [double[]]@($intervals | ForEach-Object { $_.NormalizedCpuPercent })
    $workingValues = [double[]]@($intervals | ForEach-Object { $_.WorkingSetMiB })
    $privateValues = [double[]]@($intervals | ForEach-Object { $_.PrivateMemoryMiB })
    $status = if ($MeasuredLive) { 'MEASURED_LOCAL_PROCESS' } else { 'FIXTURE_NOT_HARDWARE_EVIDENCE' }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Status = $status
        EvidenceGrade = $status
        MeasuredLive = $MeasuredLive
        Scope = 'CAAutoConfig-process-only'
        AppVersion = $AppVersion
        StartedUtc = $StartedUtc.ToUniversalTime().ToString('o')
        FinishedUtc = $FinishedUtc.ToUniversalTime().ToString('o')
        ObservedSeconds = [Math]::Round([double]$RawSamples[$RawSamples.Count - 1].elapsedSeconds, 3)
        ProcessorCount = $ProcessorCount
        SampleCount = $intervals.Count
        NonRespondingSampleCount = @($intervals | Where-Object { -not $_.Responding }).Count
        Cpu = [ordered]@{
            Unit = 'percent-of-total-logical-processor-capacity'
            Mean = [Math]::Round([double](($cpuValues | Measure-Object -Average).Average), 4)
            P95 = [Math]::Round((Get-NearestRankPercentile $cpuValues 95), 4)
            Maximum = [Math]::Round([double](($cpuValues | Measure-Object -Maximum).Maximum), 4)
        }
        WorkingSetMiB = [ordered]@{
            Mean = [Math]::Round([double](($workingValues | Measure-Object -Average).Average), 3)
            P95 = [Math]::Round((Get-NearestRankPercentile $workingValues 95), 3)
            Maximum = [Math]::Round([double](($workingValues | Measure-Object -Maximum).Maximum), 3)
        }
        PrivateMemoryMiB = [ordered]@{
            Mean = [Math]::Round([double](($privateValues | Measure-Object -Average).Average), 3)
            P95 = [Math]::Round((Get-NearestRankPercentile $privateValues 95), 3)
            Maximum = [Math]::Round([double](($privateValues | Measure-Object -Maximum).Maximum), 3)
        }
        Samples = $intervals
        Boundaries = [ordered]@{
            UniversalPerformanceClaim = $false
            PromotionAuthorized = $false
            ProcessIdExported = $false
            ExecutablePathExported = $false
            MachineOrUserIdentityExported = $false
            NetworkAccess = $false
            HardwareWrites = $false
            GpuSettingsChanged = $false
            ProcessControl = $false
        }
    }
}

$rawSamples = @()
$measuredLive = $false
$appVersion = 'fixture'
$startedUtc = [DateTime]::UtcNow
$finishedUtc = $startedUtc
$processorCount = [Environment]::ProcessorCount
$resolvedFixture = $null

if (-not [String]::IsNullOrWhiteSpace($FixturePath)) {
    $resolvedFixture = (Resolve-Path -LiteralPath $FixturePath -ErrorAction Stop).Path
    $fixture = Get-Content -LiteralPath $resolvedFixture -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-ExactProperties $fixture @('schemaVersion', 'processorCount', 'samples') 'fixture'
    if ([int]$fixture.schemaVersion -ne 1) { Stop-InvalidEvidence 'fixture schema is unsupported' }
    $processorCount = [int]$fixture.processorCount
    $rawSamples = @($fixture.samples)
    $finishedUtc = $startedUtc.AddSeconds([double]$rawSamples[$rawSamples.Count - 1].elapsedSeconds)
}
else {
    $matches = @(Get-Process -Name 'CAAutoConfig' -ErrorAction SilentlyContinue)
    if ($matches.Count -ne 1) { Stop-InvalidEvidence 'exactly one running CAAutoConfig process is required' }
    $processId = $matches[0].Id
    try {
        $fileVersion = $matches[0].MainModule.FileVersionInfo.ProductVersion
        if (-not [String]::IsNullOrWhiteSpace($fileVersion) -and $fileVersion -match '^[A-Za-z0-9][A-Za-z0-9.+ -]{0,79}$') { $appVersion = $fileVersion }
        else { $appVersion = 'unknown' }
    }
    catch { $appVersion = 'unknown' }

    $measuredLive = $true
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $baseline = Get-Process -Id $processId -ErrorAction Stop
    $rawSamples += [pscustomobject]@{
        elapsedSeconds = 0.0
        cpuSeconds = $baseline.TotalProcessorTime.TotalSeconds
        workingSetBytes = $baseline.WorkingSet64
        privateBytes = $baseline.PrivateMemorySize64
        responding = $baseline.Responding
    }
    $intervalCount = [Math]::Floor($DurationSeconds / $IntervalSeconds)
    for ($sampleIndex = 1; $sampleIndex -le $intervalCount; $sampleIndex++) {
        $targetMilliseconds = 1000 * $sampleIndex * $IntervalSeconds
        $remaining = $targetMilliseconds - $stopwatch.ElapsedMilliseconds
        if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
        $sample = Get-Process -Id $processId -ErrorAction Stop
        $rawSamples += [pscustomobject]@{
            elapsedSeconds = $stopwatch.Elapsed.TotalSeconds
            cpuSeconds = $sample.TotalProcessorTime.TotalSeconds
            workingSetBytes = $sample.WorkingSet64
            privateBytes = $sample.PrivateMemorySize64
            responding = $sample.Responding
        }
    }
    $stopwatch.Stop()
    $finishedUtc = [DateTime]::UtcNow
}

$summary = New-Summary $rawSamples $processorCount $measuredLive $appVersion $startedUtc $finishedUtc

if (-not [String]::IsNullOrWhiteSpace($ResultPath)) {
    $resolvedResult = [IO.Path]::GetFullPath($ResultPath)
    if ([String]::Equals($resolvedResult, [IO.Path]::GetFullPath($PSCommandPath), [StringComparison]::OrdinalIgnoreCase) -or
        ($null -ne $resolvedFixture -and [String]::Equals($resolvedResult, [IO.Path]::GetFullPath($resolvedFixture), [StringComparison]::OrdinalIgnoreCase))) {
        Stop-InvalidEvidence 'ResultPath cannot overwrite an input or the measurement tool'
    }
    $parent = Split-Path -Parent $resolvedResult
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { Stop-InvalidEvidence 'ResultPath parent does not exist' }
    if (Test-Path -LiteralPath $resolvedResult) { Stop-InvalidEvidence 'ResultPath already exists; refusing to overwrite evidence' }
    [IO.File]::WriteAllText($resolvedResult, ($summary | ConvertTo-Json -Depth 8) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

$summary
