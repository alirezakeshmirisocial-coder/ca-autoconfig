[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PowerAdvisor.psm1') -Force

$passed = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:passed++
    Write-Host "PASS $Name" -ForegroundColor Green
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern, [string]$Message)
    $thrown = $false
    try { & $Body }
    catch {
        $thrown = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Message Unexpected error: $($_.Exception.Message)" }
    }
    if (-not $thrown) { throw $Message }
}

$candidateText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\dual-3090-280w.json')
$referenceText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\dual-3090-350w.json')
$referenceProfile = 'GPU0 350 W + GPU1 350 W'
$candidateProfile = 'GPU0 280 W + GPU1 280 W'

function Expand-AdvisorSamples {
    param($Run)

    foreach ($gpu in @($Run.gpus)) {
        $pattern = @($gpu.samples | ForEach-Object { $_ | ConvertTo-Json -Depth 4 | ConvertFrom-Json })
        $expanded = New-Object Collections.Generic.List[object]
        $target = [int][Math]::Ceiling(($Run.protocol.sampleSeconds * 1000.0) / $Run.protocol.intervalMilliseconds)
        for ($index = 0; $index -lt $target; $index++) {
            $sample = $pattern[$index % $pattern.Count] | ConvertTo-Json -Depth 4 | ConvertFrom-Json
            $sample.elapsedMilliseconds = $index * [int]$Run.protocol.intervalMilliseconds
            if ($null -eq $sample.graphicsClockMHz) { $sample.graphicsClockMHz = 1695 }
            $expanded.Add($sample)
        }
        $gpu.samples = $expanded.ToArray()
    }
    return $Run
}

function New-AdvisorRunSet {
    param([ValidateSet('live', 'fixture')][string]$Source = 'live', [int]$Repetitions = 3)

    $list = New-Object Collections.Generic.List[object]
    foreach ($templateText in @($candidateText, $referenceText)) {
        for ($repetition = 1; $repetition -le $Repetitions; $repetition++) {
            $copy = $templateText | ConvertFrom-Json
            $copy.source = $Source
            $copy.runId = "$($copy.runId)-advisor-$Source-$repetition"
            $copy.protocol.repetition = $repetition
            $copy = Expand-AdvisorSamples -Run $copy
            $list.Add($copy)
        }
    }
    return $list.ToArray()
}

function Invoke-AdvisorGate {
    param([object[]]$Runs, [hashtable]$Override = @{})
    $parameters = @{
        Runs = $Runs
        ReferenceProfile = $referenceProfile
        CandidateProfile = $candidateProfile
        ExpectedGraphicsClockMaximumMHz = 1700
    }
    foreach ($key in $Override.Keys) { $parameters[$key] = $Override[$key] }
    return Test-CAWorkloadCandidate @parameters
}

Test-Case 'complete aligned live evidence passes only the workload gate' {
    $gate = Invoke-AdvisorGate -Runs (New-AdvisorRunSet -Source live)
    Assert-True ($gate.GateStatus -eq 'PASS' -and [bool]$gate.CanProceedPastWorkloadGate) 'Complete candidate evidence did not pass.'
    Assert-True ([double]$gate.PerformanceRetentionPercent -gt 96 -and [double]$gate.EfficiencyGainPercent -gt 19) 'Candidate comparison is wrong.'
    Assert-True (@($gate.CandidateClockEvidence).Count -eq 6) 'Per-run, per-GPU clock evidence is incomplete.'
    Assert-True (-not [bool]$gate.HardwareWrites) 'Pure advisor gate reported a hardware write.'
}

Test-Case 'fixture evidence can exercise thresholds but never pass' {
    $gate = Invoke-AdvisorGate -Runs (New-AdvisorRunSet -Source fixture)
    Assert-True ($gate.GateStatus -eq 'FIXTURE' -and [bool]$gate.WouldPassThresholds) 'Fixture threshold result is wrong.'
    Assert-True (-not [bool]$gate.CanProceedPastWorkloadGate -and @($gate.ReasonCodes) -contains 'fixture-source') 'Fixture evidence advanced the workload gate.'
}

Test-Case 'failed and incomplete candidate runs are rejected' {
    $failedRuns = @(New-AdvisorRunSet -Source live)
    $failedRuns[0].result.status = 'failed'
    $failedRuns[0].result.throughput.generationTokensPerSecond = $null
    $failedRuns[0].measurement.generationRateWindow = $null
    $failedRuns[0].result.error = 'workload exited unexpectedly'
    $failed = Invoke-AdvisorGate -Runs $failedRuns
    Assert-True ($failed.GateStatus -eq 'REJECTED' -and @($failed.ReasonCodes) -contains 'failed-or-incomplete-run') 'Failed run did not reject the candidate.'

    $incompleteRuns = @(New-AdvisorRunSet -Source live)
    $incompleteRuns[0].result.status = 'incomplete'
    $incompleteRuns[0].result.throughput.generationTokensPerSecond = $null
    $incompleteRuns[0].measurement.generationRateWindow = $null
    $incompleteRuns[0].result.error = 'measurement window ended early'
    $incomplete = Invoke-AdvisorGate -Runs $incompleteRuns
    Assert-True ($incomplete.GateStatus -eq 'REJECTED') 'Incomplete run did not reject the candidate.'
}

Test-Case 'driver reset evidence receives an explicit rejection reason' {
    $runs = @(New-AdvisorRunSet -Source live)
    $runs[0].result.status = 'failed'
    $runs[0].result.throughput.generationTokensPerSecond = $null
    $runs[0].measurement.generationRateWindow = $null
    $runs[0].result.error = 'NVIDIA driver reset; device lost'
    $gate = Invoke-AdvisorGate -Runs $runs
    Assert-True ($gate.GateStatus -eq 'REJECTED' -and @($gate.ReasonCodes) -contains 'driver-reset-evidence') 'Driver reset was not classified explicitly.'
}

Test-Case 'unstable or over-ceiling candidate clocks are rejected' {
    $unstableRuns = @(New-AdvisorRunSet -Source live)
    $clock = 1200.0
    foreach ($sample in @($unstableRuns[0].gpus[0].samples)) {
        $sample.graphicsClockMHz = $clock
        $clock = if ($clock -eq 1200.0) { 1695.0 } else { 1200.0 }
    }
    $unstable = Invoke-AdvisorGate -Runs $unstableRuns
    Assert-True ($unstable.GateStatus -eq 'REJECTED' -and @($unstable.ReasonCodes) -contains 'unstable-clock') 'Unstable clocks were accepted.'

    $ceilingRuns = @(New-AdvisorRunSet -Source live)
    $ceilingRuns[0].gpus[0].samples[0].graphicsClockMHz = 1800
    $ceiling = Invoke-AdvisorGate -Runs $ceilingRuns
    Assert-True ($ceiling.GateStatus -eq 'REJECTED' -and @($ceiling.ReasonCodes) -contains 'clock-ceiling-exceeded') 'Clock ceiling violation was accepted.'
}

Test-Case 'performance loss and weak efficiency gain reject the candidate' {
    $slowRuns = @(New-AdvisorRunSet -Source live)
    foreach ($run in @($slowRuns | Where-Object { [double]$_.gpus[0].powerLimitWatts -eq 280 })) {
        $run.result.throughput.generationTokensPerSecond = 15
    }
    $slow = Invoke-AdvisorGate -Runs $slowRuns
    Assert-True ($slow.GateStatus -eq 'REJECTED' -and @($slow.ReasonCodes) -contains 'performance-retention-too-low') 'Large throughput loss was accepted.'

    $weakRuns = @(New-AdvisorRunSet -Source live)
    foreach ($run in @($weakRuns | Where-Object { [double]$_.gpus[0].powerLimitWatts -eq 280 })) {
        foreach ($gpu in @($run.gpus)) { foreach ($sample in @($gpu.samples)) { $sample.powerDrawWatts = [double]$sample.powerDrawWatts + 45 } }
    }
    $weak = Invoke-AdvisorGate -Runs $weakRuns
    Assert-True ($weak.GateStatus -eq 'REJECTED' -and @($weak.ReasonCodes) -contains 'efficiency-gain-too-low') 'Weak efficiency improvement was accepted.'
}

Test-Case 'high temperature rejects the candidate' {
    $runs = @(New-AdvisorRunSet -Source live)
    foreach ($sample in @($runs[0].gpus[0].samples)) { $sample.temperatureC = 90 }
    $gate = Invoke-AdvisorGate -Runs $runs
    Assert-True ($gate.GateStatus -eq 'REJECTED' -and @($gate.ReasonCodes) -contains 'temperature-too-high') 'Over-temperature candidate was accepted.'
}

Test-Case 'missing telemetry and short sampling fail closed' {
    $missingRuns = @(New-AdvisorRunSet -Source live)
    $missingRuns[0].gpus[0].samples[0].powerDrawWatts = $null
    $missing = Invoke-AdvisorGate -Runs $missingRuns
    Assert-True ($missing.GateStatus -eq 'INSUFFICIENT' -and @($missing.ReasonCodes) -contains 'missing-power-telemetry') 'Missing power did not fail closed.'

    $shortRuns = @(New-AdvisorRunSet -Source live)
    foreach ($run in $shortRuns) { $run.protocol.sampleSeconds = 5 }
    $short = Invoke-AdvisorGate -Runs $shortRuns
    Assert-True ($short.GateStatus -eq 'INSUFFICIENT' -and @($short.ReasonCodes) -contains 'sample-window-too-short') 'Short runs were accepted.'
}

Test-Case 'mixed hardware, phases, and duplicate repetitions fail closed' {
    $hardwareRuns = @(New-AdvisorRunSet -Source live)
    $hardwareRuns[-1].gpus[0].driver = 'different-driver'
    $hardware = Invoke-AdvisorGate -Runs $hardwareRuns
    Assert-True (@($hardware.ReasonCodes) -contains 'mixed-hardware-or-driver') 'Mixed driver evidence was accepted.'

    $phaseRuns = @(New-AdvisorRunSet -Source live)
    $phaseRuns[0].measurement.generationRateWindow = 'generation-phase'
    $phase = Invoke-AdvisorGate -Runs $phaseRuns
    Assert-True (@($phase.ReasonCodes) -contains 'energy-window-not-aligned') 'Phase-mismatched evidence advanced.'

    $duplicateRuns = @(New-AdvisorRunSet -Source live)
    $duplicateRuns[1].protocol.repetition = 1
    $duplicate = Invoke-AdvisorGate -Runs $duplicateRuns
    Assert-True (@($duplicate.ReasonCodes) -contains 'duplicate-candidate-repetition') 'Duplicate candidate repetitions were accepted.'
}

Test-Case 'generalized work-unit evidence uses the same safety gate' {
    $runs = @(New-AdvisorRunSet -Source live)
    foreach ($run in $runs) {
        $rate = if ([double]$run.gpus[0].powerLimitWatts -eq 280) { 0.25 } else { 0.255 }
        $run.result.throughput.generationTokensPerSecond = $null
        $run.result.throughput.workUnitsPerSecond = $rate
        $run.result.throughput.workUnit = 'image'
        $run.measurement.generationRateWindow = $null
        $run.measurement.workRateWindow = 'steady-state'
    }
    $gate = Invoke-AdvisorGate -Runs $runs
    Assert-True ($gate.GateStatus -eq 'PASS' -and $gate.MetricMode -eq 'work-unit' -and $gate.WorkUnit -eq 'image') 'Work-unit candidate did not use the shared gate.'
}

Test-Case 'report preserves all remaining safety boundaries' {
    $runs = New-AdvisorRunSet -Source live
    $markdown = New-CAWorkloadCandidateMarkdown -Runs $runs -ReferenceProfile $referenceProfile -CandidateProfile $candidateProfile -ExpectedGraphicsClockMaximumMHz 1700
    Assert-True ($markdown -match 'separate idle-power, privilege, confirmation, and rollback gates') 'Passing report skips remaining gates.'
    Assert-True ($markdown -match 'cannot apply a GPU setting') 'Read-only boundary is missing.'
    Assert-True ($markdown -match 'Loaded clock samples') 'Clock evidence table is missing.'
}

Test-Case 'dry-run report is deterministic fixture evidence without hardware access' {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('ca-workload-gate-' + [Guid]::NewGuid().ToString('N') + '.md')
    try {
        $result = & (Join-Path $PSScriptRoot 'New-WorkloadCandidateReport.ps1') -DryRun -OutputPath $temporary
        $content = Get-Content -Raw -LiteralPath $temporary
        Assert-True ($result.GateStatus -eq 'FIXTURE' -and [int]$result.Runs -eq 6) 'Dry-run workload gate result is wrong.'
        Assert-True (-not [bool]$result.HardwareReads -and -not [bool]$result.HardwareWrites) 'Dry-run reported hardware access.'
        Assert-True ($content -match 'Synthetic evidence can exercise this gate') 'Fixture boundary is missing.'
        Assert-True ($content -notmatch '(?i)GPU-[0-9a-f-]{12,}|[a-z]:\\users\\') 'Dry-run report leaked a protected identifier.'
    }
    finally { Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $temporary }
}

Test-Case 'advisor source has no hardware mutation path' {
    $source = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'PowerAdvisor.psm1')
    $reportSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'New-WorkloadCandidateReport.ps1')
    Assert-True (($source + $reportSource) -notmatch '(?im)(?:^|\s)-(?:pl|lgc|rgc|rac|ac)\b') 'Advisor contains an NVIDIA mutation flag.'
    Assert-True (($source + $reportSource) -notmatch 'Start-Process|Start-ScheduledTask|Register-ScheduledTask|Verb\s+RunAs') 'Advisor contains a process, elevation, or task path.'
}

Test-Case 'same reference and candidate profile is rejected before analysis' {
    Assert-Throws {
        Test-CAWorkloadCandidate -Runs (New-AdvisorRunSet -Source live) -ReferenceProfile $referenceProfile -CandidateProfile $referenceProfile -ExpectedGraphicsClockMaximumMHz 1700 | Out-Null
    } 'must be different' 'Identical reference and candidate profiles were accepted.'
}

Write-Host "$passed workload-advisor gate tests passed. No GPU settings were read or changed by the fixture suite." -ForegroundColor Cyan
