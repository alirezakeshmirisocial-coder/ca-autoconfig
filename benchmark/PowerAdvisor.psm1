Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PowerCurve.psm1') -Force

function Test-CAAdvisorFiniteNumber {
    param($Value)

    if ($null -eq $Value) { return $false }
    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $false
    }
    return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
}

function Get-CAAdvisorAverage {
    param([object[]]$Values)

    $finite = @($Values | Where-Object { Test-CAAdvisorFiniteNumber $_ } | ForEach-Object { [double]$_ })
    if ($finite.Count -eq 0) { return $null }
    return [Math]::Round((($finite | Measure-Object -Average).Average), 6)
}

function Get-CAAdvisorPercentile {
    param([object[]]$Values, [ValidateRange(0, 100)][double]$Percentile)

    $finite = @($Values | Where-Object { Test-CAAdvisorFiniteNumber $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($finite.Count -eq 0) { return $null }
    if ($finite.Count -eq 1) { return [Math]::Round($finite[0], 6) }
    $position = ($Percentile / 100.0) * ($finite.Count - 1)
    $lower = [int][Math]::Floor($position)
    $upper = [int][Math]::Ceiling($position)
    if ($lower -eq $upper) { return [Math]::Round($finite[$lower], 6) }
    $weight = $position - $lower
    return [Math]::Round(($finite[$lower] + (($finite[$upper] - $finite[$lower]) * $weight)), 6)
}

function Get-CAAdvisorHardwareKey {
    param($Run)

    return @($Run.gpus | Sort-Object { [int]$_.index } | ForEach-Object {
        '{0}:{1}:{2}' -f [int]$_.index, [string]$_.model, [string]$_.driver
    }) -join '|'
}

function Get-CAAdvisorWorkloadKey {
    param($Run)

    return @(
        [string]$Run.workload.class,
        [string]$Run.workload.name,
        [string]$Run.workload.model,
        [string]$Run.workload.quantization,
        [string]$Run.workload.backend
    ) -join '|'
}

function Test-CAWorkloadCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Runs,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ReferenceProfile,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$CandidateProfile,
        [Parameter(Mandatory = $true)][ValidateRange(1, 10000)][double]$ExpectedGraphicsClockMaximumMHz,
        [ValidateRange(1, 100)][int]$MinimumRepetitions = 3,
        [ValidateRange(1, 3600)][int]$MinimumSampleSeconds = 30,
        [ValidateRange(0, 100)][double]$MinimumPerformanceRetentionPercent = 90,
        [ValidateRange(0, 1000)][double]$MinimumEfficiencyGainPercent = 5,
        [ValidateRange(-50, 150)][double]$MaximumPeakTemperatureC = 85,
        [ValidateRange(0, 100)][double]$MinimumClockSampleUtilizationPercent = 50,
        [ValidateRange(1, 10000)][int]$MinimumClockSamplesPerGpuRun = 3,
        [ValidateRange(0, 100)][double]$MaximumClockSpreadPercent = 5,
        [ValidateRange(0, 1000)][double]$MaximumClockCeilingToleranceMHz = 30
    )

    if ($ReferenceProfile -eq $CandidateProfile) { throw 'ReferenceProfile and CandidateProfile must be different.' }
    $runsArray = @($Runs)
    if ($runsArray.Count -lt 2) { throw 'Workload candidate analysis requires at least two run exports.' }
    $rows = @(ConvertTo-CAPowerCurveRows -Runs $runsArray)
    $reasons = New-Object Collections.Generic.List[string]

    $sources = @($runsArray | ForEach-Object { [string]$_.source } | Select-Object -Unique)
    $fixtureOnly = $sources.Count -eq 1 -and $sources[0] -eq 'fixture'
    if ($sources.Count -ne 1) { $reasons.Add('mixed-evidence-sources') }
    if (@($runsArray | ForEach-Object { Get-CAAdvisorWorkloadKey $_ } | Select-Object -Unique).Count -ne 1) {
        $reasons.Add('mixed-workloads')
    }
    if (@($runsArray | ForEach-Object { [string]$_.runId } | Select-Object -Unique).Count -ne $runsArray.Count) {
        $reasons.Add('duplicate-run-id')
    }

    $pairs = New-Object Collections.Generic.List[object]
    for ($index = 0; $index -lt $runsArray.Count; $index++) {
        if ($rows[$index].Profile -in @($ReferenceProfile, $CandidateProfile)) {
            $pairs.Add([pscustomobject]@{ Run = $runsArray[$index]; Row = $rows[$index] })
        }
    }
    $reference = @($pairs | Where-Object { $_.Row.Profile -eq $ReferenceProfile })
    $candidate = @($pairs | Where-Object { $_.Row.Profile -eq $CandidateProfile })
    if ($reference.Count -eq 0) { $reasons.Add('reference-profile-missing') }
    if ($candidate.Count -eq 0) { $reasons.Add('candidate-profile-missing') }
    if ($reference.Count -lt $MinimumRepetitions -or $candidate.Count -lt $MinimumRepetitions) {
        $reasons.Add('insufficient-repetitions')
    }
    if ($reference.Count -gt 0 -and @($reference | ForEach-Object { $_.Row.Repetition } | Select-Object -Unique).Count -ne $reference.Count) {
        $reasons.Add('duplicate-reference-repetition')
    }
    if ($candidate.Count -gt 0 -and @($candidate | ForEach-Object { $_.Row.Repetition } | Select-Object -Unique).Count -ne $candidate.Count) {
        $reasons.Add('duplicate-candidate-repetition')
    }

    $selected = @($reference) + @($candidate)
    if (@($selected | Where-Object { $_.Row.Status -ne 'passed' }).Count -gt 0) {
        $reasons.Add('failed-or-incomplete-run')
    }
    $errors = @($selected | ForEach-Object { $_.Run.result.error } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if (@($errors | Where-Object { [string]$_ -match '(?i)(driver\s*reset|gpu\s*reset|device\s*lost|\bXid\b)' }).Count -gt 0) {
        $reasons.Add('driver-reset-evidence')
    }
    if (@($selected | Where-Object { [int]$_.Run.schemaVersion -ne 3 }).Count -gt 0) {
        $reasons.Add('schema-v3-required')
    }
    if ($selected.Count -gt 0 -and @($selected | ForEach-Object { Get-CAAdvisorHardwareKey $_.Run } | Select-Object -Unique).Count -ne 1) {
        $reasons.Add('mixed-hardware-or-driver')
    }
    if (@($selected | Where-Object { [int]$_.Run.protocol.sampleSeconds -lt $MinimumSampleSeconds }).Count -gt 0) {
        $reasons.Add('sample-window-too-short')
    }

    $passed = @($selected | Where-Object { $_.Row.Status -eq 'passed' })
    $tokenPassed = @($passed | Where-Object { $null -ne $_.Row.GenerationTokensPerSecond })
    $workPassed = @($passed | Where-Object { $null -ne $_.Row.WorkUnitsPerSecond })
    $metricMode = $null
    $unit = $null
    if ($tokenPassed.Count -eq $passed.Count -and $passed.Count -gt 0) {
        $metricMode = 'generation-token'
        $unit = 'token'
    }
    elseif ($workPassed.Count -eq $passed.Count -and $passed.Count -gt 0 -and
        @($workPassed | ForEach-Object { $_.Row.WorkUnit } | Select-Object -Unique).Count -eq 1) {
        $metricMode = 'work-unit'
        $unit = [string]$workPassed[0].Row.WorkUnit
    }
    else {
        $reasons.Add('one-complete-metric-required')
    }

    if ($null -ne $metricMode) {
        $aligned = if ($metricMode -eq 'generation-token') {
            @($passed | Where-Object { -not $_.Row.GenerationEnergyAligned }).Count -eq 0
        }
        else {
            @($passed | Where-Object { -not $_.Row.WorkEnergyAligned }).Count -eq 0
        }
        if (-not $aligned) { $reasons.Add('energy-window-not-aligned') }
        $phaseKeys = @($passed | ForEach-Object {
            $rateWindow = if ($metricMode -eq 'generation-token') { $_.Row.GenerationRateWindow } else { $_.Row.WorkRateWindow }
            '{0}|{1}' -f $_.Row.PowerWindow, $rateWindow
        } | Select-Object -Unique)
        if ($phaseKeys.Count -ne 1) { $reasons.Add('mixed-phase-provenance') }
    }

    $candidateClockRows = New-Object Collections.Generic.List[object]
    foreach ($pair in @($passed)) {
        $run = $pair.Run
        $row = $pair.Row
        $expectedSamplesPerGpu = [int][Math]::Ceiling(([int]$run.protocol.sampleSeconds * 1000.0) / [int]$run.protocol.intervalMilliseconds)
        foreach ($gpu in @($run.gpus)) {
            $samples = @($gpu.samples)
            if ($samples.Count -lt $expectedSamplesPerGpu) { $reasons.Add('sample-count-too-short') }
            if (@($samples | Where-Object { $null -eq $_.powerDrawWatts }).Count -gt 0) { $reasons.Add('missing-power-telemetry') }
            if (@($samples | Where-Object { $null -eq $_.temperatureC }).Count -gt 0) { $reasons.Add('missing-temperature-telemetry') }
            if ($row.Profile -ne $CandidateProfile) { continue }
            if (@($samples | Where-Object { $null -eq $_.utilizationPercent }).Count -gt 0) {
                $reasons.Add('missing-utilization-telemetry')
                continue
            }
            $loadedSamples = @($samples | Where-Object {
                $null -ne $_.utilizationPercent -and [double]$_.utilizationPercent -ge $MinimumClockSampleUtilizationPercent
            })
            $loadedClocks = @($loadedSamples | ForEach-Object { $_.graphicsClockMHz } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
            if ($loadedSamples.Count -lt $MinimumClockSamplesPerGpuRun -or $loadedClocks.Count -ne $loadedSamples.Count) {
                $reasons.Add('missing-clock-telemetry')
                continue
            }
            $p05 = Get-CAAdvisorPercentile -Values $loadedClocks -Percentile 5
            $p50 = Get-CAAdvisorPercentile -Values $loadedClocks -Percentile 50
            $p95 = Get-CAAdvisorPercentile -Values $loadedClocks -Percentile 95
            if ($null -eq $p50 -or [double]$p50 -le 0) {
                $reasons.Add('missing-clock-telemetry')
                continue
            }
            $spread = [Math]::Round((([double]$p95 - [double]$p05) / [double]$p50) * 100.0, 6)
            $ceilingExceeded = @($loadedClocks | Where-Object {
                [double]$_ -gt ($ExpectedGraphicsClockMaximumMHz + $MaximumClockCeilingToleranceMHz)
            }).Count -gt 0
            if ($spread -gt $MaximumClockSpreadPercent) { $reasons.Add('unstable-clock') }
            if ($ceilingExceeded) { $reasons.Add('clock-ceiling-exceeded') }
            $candidateClockRows.Add([pscustomobject][ordered]@{
                RunId = [string]$run.runId
                GpuIndex = [int]$gpu.index
                LoadedSamples = $loadedClocks.Count
                P05MHz = [double]$p05
                MedianMHz = [double]$p50
                P95MHz = [double]$p95
                SpreadPercent = $spread
                CeilingExceeded = $ceilingExceeded
            })
        }
    }

    $referencePassed = @($reference | Where-Object { $_.Row.Status -eq 'passed' })
    $candidatePassed = @($candidate | Where-Object { $_.Row.Status -eq 'passed' })
    $referenceRate = $null
    $candidateRate = $null
    $referencePower = Get-CAAdvisorAverage -Values @($referencePassed | ForEach-Object { $_.Row.MeanBoardPowerWatts })
    $candidatePower = Get-CAAdvisorAverage -Values @($candidatePassed | ForEach-Object { $_.Row.MeanBoardPowerWatts })
    if ($metricMode -eq 'generation-token') {
        $referenceRate = Get-CAAdvisorAverage -Values @($referencePassed | ForEach-Object { $_.Row.GenerationTokensPerSecond })
        $candidateRate = Get-CAAdvisorAverage -Values @($candidatePassed | ForEach-Object { $_.Row.GenerationTokensPerSecond })
    }
    elseif ($metricMode -eq 'work-unit') {
        $referenceRate = Get-CAAdvisorAverage -Values @($referencePassed | ForEach-Object { $_.Row.WorkUnitsPerSecond })
        $candidateRate = Get-CAAdvisorAverage -Values @($candidatePassed | ForEach-Object { $_.Row.WorkUnitsPerSecond })
    }
    $retention = $null
    $efficiencyGain = $null
    $referenceEfficiency = $null
    $candidateEfficiency = $null
    if ($null -ne $referenceRate -and [double]$referenceRate -gt 0 -and $null -ne $candidateRate) {
        $retention = [Math]::Round(([double]$candidateRate / [double]$referenceRate) * 100.0, 6)
        if ($retention -lt $MinimumPerformanceRetentionPercent) { $reasons.Add('performance-retention-too-low') }
    }
    else { $reasons.Add('throughput-comparison-incomplete') }
    if ($null -ne $referencePower -and [double]$referencePower -gt 0 -and $null -ne $candidatePower -and
        $null -ne $referenceRate -and $null -ne $candidateRate) {
        if ([double]$candidatePower -ge [double]$referencePower) { $reasons.Add('candidate-not-lower-power') }
        $referenceEfficiency = [Math]::Round(([double]$referenceRate / [double]$referencePower), 9)
        $candidateEfficiency = [Math]::Round(([double]$candidateRate / [double]$candidatePower), 9)
        $efficiencyGain = [Math]::Round((($candidateEfficiency / $referenceEfficiency) - 1.0) * 100.0, 6)
        if ($efficiencyGain -lt $MinimumEfficiencyGainPercent) { $reasons.Add('efficiency-gain-too-low') }
    }
    else { $reasons.Add('power-comparison-incomplete') }

    $candidatePeakValues = @($candidatePassed | ForEach-Object { $_.Row.PeakTemperatureC } | Where-Object { $null -ne $_ })
    $candidatePeak = if ($candidatePeakValues.Count -eq 0) { $null } else { [double](($candidatePeakValues | Measure-Object -Maximum).Maximum) }
    if ($null -eq $candidatePeak) { $reasons.Add('temperature-comparison-incomplete') }
    elseif ($candidatePeak -gt $MaximumPeakTemperatureC) { $reasons.Add('temperature-too-high') }

    $reasonCodes = @($reasons | Select-Object -Unique)
    $hardRejectReasons = @(
        'driver-reset-evidence', 'failed-or-incomplete-run', 'candidate-not-lower-power',
        'performance-retention-too-low', 'efficiency-gain-too-low', 'temperature-too-high',
        'unstable-clock', 'clock-ceiling-exceeded'
    )
    $gateStatus = if ($fixtureOnly -and $sources.Count -eq 1) {
        'FIXTURE'
    }
    elseif (@($reasonCodes | Where-Object { $_ -in $hardRejectReasons }).Count -gt 0) {
        'REJECTED'
    }
    elseif ($reasonCodes.Count -gt 0) {
        'INSUFFICIENT'
    }
    else {
        'PASS'
    }
    $wouldPass = $reasonCodes.Count -eq 0
    if ($fixtureOnly) { $reasonCodes = @('fixture-source') + $reasonCodes }

    return [pscustomobject][ordered]@{
        GateStatus = $gateStatus
        CanProceedPastWorkloadGate = $gateStatus -eq 'PASS'
        WouldPassThresholds = $wouldPass
        ReasonCodes = @($reasonCodes)
        Workload = if ($runsArray.Count -eq 0) { $null } else { [string]$runsArray[0].workload.name }
        MetricMode = $metricMode
        WorkUnit = $unit
        ReferenceProfile = $ReferenceProfile
        CandidateProfile = $CandidateProfile
        ReferenceRepetitions = $reference.Count
        CandidateRepetitions = $candidate.Count
        ReferenceMeanRate = $referenceRate
        CandidateMeanRate = $candidateRate
        PerformanceRetentionPercent = $retention
        ReferenceMeanBoardPowerWatts = $referencePower
        CandidateMeanBoardPowerWatts = $candidatePower
        ReferenceEfficiency = $referenceEfficiency
        CandidateEfficiency = $candidateEfficiency
        EfficiencyGainPercent = $efficiencyGain
        CandidatePeakTemperatureC = $candidatePeak
        ExpectedGraphicsClockMaximumMHz = $ExpectedGraphicsClockMaximumMHz
        CandidateClockEvidence = $candidateClockRows.ToArray()
        Thresholds = [pscustomobject][ordered]@{
            MinimumRepetitions = $MinimumRepetitions
            MinimumSampleSeconds = $MinimumSampleSeconds
            MinimumPerformanceRetentionPercent = $MinimumPerformanceRetentionPercent
            MinimumEfficiencyGainPercent = $MinimumEfficiencyGainPercent
            MaximumPeakTemperatureC = $MaximumPeakTemperatureC
            MinimumClockSampleUtilizationPercent = $MinimumClockSampleUtilizationPercent
            MinimumClockSamplesPerGpuRun = $MinimumClockSamplesPerGpuRun
            MaximumClockSpreadPercent = $MaximumClockSpreadPercent
            MaximumClockCeilingToleranceMHz = $MaximumClockCeilingToleranceMHz
        }
        HardwareWrites = $false
    }
}

function Format-CAAdvisorMarkdownValue {
    param($Value, [string]$Format = '0.###')

    if ($null -eq $Value) { return 'N/A' }
    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        return ([double]$Value).ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
    }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function New-CAWorkloadCandidateMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Runs,
        [Parameter(Mandatory = $true)][string]$ReferenceProfile,
        [Parameter(Mandatory = $true)][string]$CandidateProfile,
        [Parameter(Mandatory = $true)][double]$ExpectedGraphicsClockMaximumMHz,
        [ValidateRange(1, 100)][int]$MinimumRepetitions = 3,
        [ValidateRange(1, 3600)][int]$MinimumSampleSeconds = 30,
        [ValidateRange(0, 100)][double]$MinimumPerformanceRetentionPercent = 90,
        [ValidateRange(0, 1000)][double]$MinimumEfficiencyGainPercent = 5,
        [ValidateRange(-50, 150)][double]$MaximumPeakTemperatureC = 85,
        [ValidateRange(0, 100)][double]$MinimumClockSampleUtilizationPercent = 50,
        [ValidateRange(1, 10000)][int]$MinimumClockSamplesPerGpuRun = 3,
        [ValidateRange(0, 100)][double]$MaximumClockSpreadPercent = 5,
        [ValidateRange(0, 1000)][double]$MaximumClockCeilingToleranceMHz = 30
    )

    $parameters = @{
        Runs = $Runs
        ReferenceProfile = $ReferenceProfile
        CandidateProfile = $CandidateProfile
        ExpectedGraphicsClockMaximumMHz = $ExpectedGraphicsClockMaximumMHz
        MinimumRepetitions = $MinimumRepetitions
        MinimumSampleSeconds = $MinimumSampleSeconds
        MinimumPerformanceRetentionPercent = $MinimumPerformanceRetentionPercent
        MinimumEfficiencyGainPercent = $MinimumEfficiencyGainPercent
        MaximumPeakTemperatureC = $MaximumPeakTemperatureC
        MinimumClockSampleUtilizationPercent = $MinimumClockSampleUtilizationPercent
        MinimumClockSamplesPerGpuRun = $MinimumClockSamplesPerGpuRun
        MaximumClockSpreadPercent = $MaximumClockSpreadPercent
        MaximumClockCeilingToleranceMHz = $MaximumClockCeilingToleranceMHz
    }
    $gate = Test-CAWorkloadCandidate @parameters
    $rateUnit = if ($gate.MetricMode -eq 'generation-token') { 'tok/s' } elseif ($gate.MetricMode -eq 'work-unit') { "$($gate.WorkUnit)/s" } else { 'unit/s' }
    $efficiencyUnit = if ($gate.MetricMode -eq 'generation-token') { 'tokens/J' } elseif ($gate.MetricMode -eq 'work-unit') { "$($gate.WorkUnit)/J" } else { 'unit/J' }
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# CA AutoConfig workload candidate gate')
    $lines.Add('')
    $lines.Add(('**Gate status:** `{0}`' -f $gate.GateStatus))
    $lines.Add('')
    $lines.Add('This report is read-only. It evaluates one explicitly named candidate against one explicitly named reference and cannot apply a GPU setting.')
    $lines.Add('')
    $lines.Add(('- Workload: `{0}`' -f (Format-CAAdvisorMarkdownValue $gate.Workload)))
    $lines.Add(('- Reference: `{0}` ({1} runs; {2} {3}; {4} W)' -f
        (Format-CAAdvisorMarkdownValue $gate.ReferenceProfile), $gate.ReferenceRepetitions,
        (Format-CAAdvisorMarkdownValue $gate.ReferenceMeanRate), $rateUnit,
        (Format-CAAdvisorMarkdownValue $gate.ReferenceMeanBoardPowerWatts)))
    $lines.Add(('- Candidate: `{0}` ({1} runs; {2} {3}; {4} W; {5} C peak)' -f
        (Format-CAAdvisorMarkdownValue $gate.CandidateProfile), $gate.CandidateRepetitions,
        (Format-CAAdvisorMarkdownValue $gate.CandidateMeanRate), $rateUnit,
        (Format-CAAdvisorMarkdownValue $gate.CandidateMeanBoardPowerWatts),
        (Format-CAAdvisorMarkdownValue $gate.CandidatePeakTemperatureC)))
    $lines.Add(('- Performance retained: `{0}%` (minimum `{1}%`)' -f
        (Format-CAAdvisorMarkdownValue $gate.PerformanceRetentionPercent),
        (Format-CAAdvisorMarkdownValue $MinimumPerformanceRetentionPercent)))
    $lines.Add(('- Efficiency gain: `{0}%` (minimum `{1}%`; metric `{2}`)' -f
        (Format-CAAdvisorMarkdownValue $gate.EfficiencyGainPercent),
        (Format-CAAdvisorMarkdownValue $MinimumEfficiencyGainPercent), $efficiencyUnit))
    $lines.Add('')
    $lines.Add('| Run | GPU | Loaded clock samples | p05 MHz | Median MHz | p95 MHz | Spread % | Ceiling exceeded |')
    $lines.Add('| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |')
    foreach ($clock in @($gate.CandidateClockEvidence)) {
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f
            (Format-CAAdvisorMarkdownValue $clock.RunId), $clock.GpuIndex, $clock.LoadedSamples,
            (Format-CAAdvisorMarkdownValue $clock.P05MHz),
            (Format-CAAdvisorMarkdownValue $clock.MedianMHz),
            (Format-CAAdvisorMarkdownValue $clock.P95MHz),
            (Format-CAAdvisorMarkdownValue $clock.SpreadPercent),
            $(if ($clock.CeilingExceeded) { 'yes' } else { 'no' })))
    }
    $lines.Add('')
    if (@($gate.ReasonCodes).Count -gt 0) {
        $lines.Add(('Reason codes: `{0}`.' -f (@($gate.ReasonCodes) -join '`, `')))
        $lines.Add('')
    }
    if ($gate.GateStatus -eq 'PASS') {
        $lines.Add('**Decision:** workload evidence permits the candidate to proceed to the separate idle-power, privilege, confirmation, and rollback gates. It is not yet an apply recommendation.')
    }
    elseif ($gate.GateStatus -eq 'REJECTED') {
        $lines.Add('**Decision:** rejected. At least one measured failure or declared safety/performance threshold blocks this candidate.')
    }
    elseif ($gate.GateStatus -eq 'FIXTURE') {
        $lines.Add('**Decision:** fixture only. Synthetic evidence can exercise this gate but can never authorize a hardware recommendation.')
    }
    else {
        $lines.Add('**Decision:** insufficient evidence. Repair or collect the missing repeated workload evidence before evaluating this candidate.')
    }
    return $lines -join "`n"
}

Export-ModuleMember -Function @(
    'Test-CAWorkloadCandidate',
    'New-CAWorkloadCandidateMarkdown'
)
