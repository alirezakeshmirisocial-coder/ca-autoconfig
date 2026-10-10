Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PowerCurve.psm1') -Force

function Assert-CAIdleProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        throw "Missing required property '$Path.$Name'."
    }
}

function Test-CAIdleFiniteNumber {
    param($Value)

    if ($null -eq $Value) { return $false }
    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $false
    }
    return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
}

function Get-CAIdleAverage {
    param([object[]]$Values)

    $finite = @($Values | Where-Object { Test-CAIdleFiniteNumber $_ } | ForEach-Object { [double]$_ })
    if ($finite.Count -eq 0) { return $null }
    return [Math]::Round((($finite | Measure-Object -Average).Average), 3)
}

function Get-CAIdlePercentile {
    param([object[]]$Values, [ValidateRange(0, 100)][double]$Percentile)

    $finite = @($Values | Where-Object { Test-CAIdleFiniteNumber $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($finite.Count -eq 0) { return $null }
    if ($finite.Count -eq 1) { return [Math]::Round($finite[0], 3) }
    $position = ($Percentile / 100.0) * ($finite.Count - 1)
    $lower = [int][Math]::Floor($position)
    $upper = [int][Math]::Ceiling($position)
    if ($lower -eq $upper) { return [Math]::Round($finite[$lower], 3) }
    $weight = $position - $lower
    return [Math]::Round(($finite[$lower] + (($finite[$upper] - $finite[$lower]) * $weight)), 3)
}

function Assert-CAIdlePowerRun {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Run)

    foreach ($name in @('schemaVersion', 'runId', 'createdUtc', 'source', 'condition', 'privacy', 'profile', 'protocol', 'result', 'gpus')) {
        Assert-CAIdleProperty -Object $Run -Name $name -Path 'run'
    }
    if ([int]$Run.schemaVersion -ne 1) { throw "Unsupported idle-power schema version '$($Run.schemaVersion)'." }
    if ([string]::IsNullOrWhiteSpace([string]$Run.runId)) { throw 'run.runId must not be empty.' }
    if ([string]$Run.source -notin @('live', 'fixture')) { throw "Unsupported idle-power source '$($Run.source)'." }
    if ([string]$Run.condition -notin @('baseline', 'candidate')) { throw "Unsupported idle-power condition '$($Run.condition)'." }

    foreach ($name in @('containsGpuUuid', 'containsMachineName', 'containsUserName', 'containsPaths', 'containsRawCommand')) {
        Assert-CAIdleProperty -Object $Run.privacy -Name $name -Path 'run.privacy'
        if ([bool]$Run.privacy.$name) { throw "run.privacy.$name must be false for an exportable run." }
    }

    foreach ($name in @('label', 'clockPolicy', 'graphicsClockMaximumMHz')) {
        Assert-CAIdleProperty -Object $Run.profile -Name $name -Path 'run.profile'
    }
    if ([string]$Run.profile.label -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._+/-]{0,79}$') {
        throw 'run.profile.label must be a short, portable label.'
    }
    if ([string]$Run.profile.clockPolicy -notin @('vendor-auto', 'persistent-graphics-lock', 'unknown')) {
        throw "Unsupported clock policy '$($Run.profile.clockPolicy)'."
    }
    if ($null -ne $Run.profile.graphicsClockMaximumMHz -and
        (-not (Test-CAIdleFiniteNumber $Run.profile.graphicsClockMaximumMHz) -or [double]$Run.profile.graphicsClockMaximumMHz -le 0)) {
        throw 'run.profile.graphicsClockMaximumMHz must be null or a positive finite number.'
    }
    if ([string]$Run.profile.clockPolicy -eq 'persistent-graphics-lock' -and $null -eq $Run.profile.graphicsClockMaximumMHz) {
        throw 'A persistent graphics-clock lock requires graphicsClockMaximumMHz.'
    }
    if ([string]$Run.profile.clockPolicy -eq 'vendor-auto' -and $null -ne $Run.profile.graphicsClockMaximumMHz) {
        throw 'A vendor-auto baseline must not declare graphicsClockMaximumMHz.'
    }

    foreach ($name in @('settleSeconds', 'sampleSeconds', 'intervalMilliseconds', 'repetition')) {
        Assert-CAIdleProperty -Object $Run.protocol -Name $name -Path 'run.protocol'
    }
    if ([int]$Run.protocol.settleSeconds -lt 0 -or [int]$Run.protocol.sampleSeconds -lt 1 -or
        [int]$Run.protocol.intervalMilliseconds -lt 250 -or [int]$Run.protocol.repetition -lt 1) {
        throw 'run.protocol contains an invalid duration, interval, or repetition.'
    }

    foreach ($name in @('status', 'error')) {
        Assert-CAIdleProperty -Object $Run.result -Name $name -Path 'run.result'
    }
    if ([string]$Run.result.status -notin @('passed', 'failed', 'incomplete')) {
        throw "Unsupported idle-power result status '$($Run.result.status)'."
    }
    if ([string]$Run.result.status -eq 'passed' -and $null -ne $Run.result.error) {
        throw 'A passed idle-power run must have a null error.'
    }
    if ([string]$Run.result.status -ne 'passed' -and [string]::IsNullOrWhiteSpace([string]$Run.result.error)) {
        throw 'A failed or incomplete idle-power run must retain an error.'
    }

    $gpus = @($Run.gpus)
    if ($gpus.Count -lt 1) { throw 'run.gpus must contain at least one GPU.' }
    $indexes = New-Object Collections.Generic.List[int]
    foreach ($gpu in $gpus) {
        foreach ($name in @('index', 'model', 'driver', 'powerLimitWatts', 'samples')) {
            Assert-CAIdleProperty -Object $gpu -Name $name -Path 'run.gpus[]'
        }
        if ([int]$gpu.index -lt 0) { throw 'run.gpus[].index must be non-negative.' }
        if ($indexes.Contains([int]$gpu.index)) { throw 'run.gpus contains a duplicate GPU index.' }
        $indexes.Add([int]$gpu.index)
        if ([string]::IsNullOrWhiteSpace([string]$gpu.model) -or [string]::IsNullOrWhiteSpace([string]$gpu.driver)) {
            throw 'run.gpus[].model and driver must not be empty.'
        }
        if ($null -ne $gpu.powerLimitWatts -and
            (-not (Test-CAIdleFiniteNumber $gpu.powerLimitWatts) -or [double]$gpu.powerLimitWatts -le 0)) {
            throw 'run.gpus[].powerLimitWatts must be null or a positive finite number.'
        }

        $samples = @($gpu.samples)
        if ($samples.Count -lt 1) { throw 'Every GPU needs at least one idle telemetry sample.' }
        $lastElapsed = -1.0
        foreach ($sample in $samples) {
            foreach ($name in @('elapsedMilliseconds', 'powerDrawWatts', 'temperatureC', 'utilizationPercent', 'graphicsClockMHz')) {
                Assert-CAIdleProperty -Object $sample -Name $name -Path 'run.gpus[].samples[]'
            }
            if (-not (Test-CAIdleFiniteNumber $sample.elapsedMilliseconds) -or [double]$sample.elapsedMilliseconds -lt 0) {
                throw 'Sample elapsedMilliseconds must be a non-negative finite number.'
            }
            if ([double]$sample.elapsedMilliseconds -lt $lastElapsed) {
                throw 'Idle samples must be ordered by elapsedMilliseconds.'
            }
            $lastElapsed = [double]$sample.elapsedMilliseconds
            foreach ($name in @('powerDrawWatts', 'temperatureC', 'utilizationPercent', 'graphicsClockMHz')) {
                $value = $sample.$name
                if ($null -ne $value -and -not (Test-CAIdleFiniteNumber $value)) {
                    throw "Sample $name must be null or finite."
                }
            }
            if ($null -ne $sample.powerDrawWatts -and [double]$sample.powerDrawWatts -lt 0) {
                throw 'Sample powerDrawWatts must not be negative.'
            }
            if ($null -ne $sample.utilizationPercent -and
                ([double]$sample.utilizationPercent -lt 0 -or [double]$sample.utilizationPercent -gt 100)) {
                throw 'Sample utilizationPercent must be between 0 and 100.'
            }
            if ($null -ne $sample.graphicsClockMHz -and [double]$sample.graphicsClockMHz -lt 0) {
                throw 'Sample graphicsClockMHz must not be negative.'
            }
        }
    }

    Assert-CAPowerCurvePrivacy -Run $Run | Out-Null
    return $Run
}

function ConvertTo-CAIdlePowerRows {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Runs)

    $rows = foreach ($run in @($Runs)) {
        Assert-CAIdlePowerRun -Run $run | Out-Null
        $expectedSamplesPerGpu = [int][Math]::Ceiling(([int]$run.protocol.sampleSeconds * 1000.0) / [int]$run.protocol.intervalMilliseconds)
        $missingPower = 0
        $missingUtilization = 0
        $sampleShortfall = 0
        $allUtilization = New-Object Collections.Generic.List[double]
        $perGpu = foreach ($gpu in @($run.gpus | Sort-Object { [int]$_.index })) {
            $samples = @($gpu.samples)
            $sampleShortfall += [Math]::Max(0, $expectedSamplesPerGpu - $samples.Count)
            $power = @($samples | ForEach-Object { $_.powerDrawWatts } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
            $utilization = @($samples | ForEach-Object { $_.utilizationPercent } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
            $clocks = @($samples | ForEach-Object { $_.graphicsClockMHz } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
            $missingPower += $samples.Count - $power.Count
            $missingUtilization += $samples.Count - $utilization.Count
            foreach ($value in $utilization) { $allUtilization.Add($value) }
            [pscustomobject][ordered]@{
                Index = [int]$gpu.index
                Model = [string]$gpu.model
                Driver = [string]$gpu.driver
                PowerLimitWatts = if ($null -eq $gpu.powerLimitWatts) { $null } else { [double]$gpu.powerLimitWatts }
                MeanPowerWatts = Get-CAIdleAverage -Values $power
                MeanUtilizationPercent = Get-CAIdleAverage -Values $utilization
                P95UtilizationPercent = Get-CAIdlePercentile -Values $utilization -Percentile 95
                MeanGraphicsClockMHz = Get-CAIdleAverage -Values $clocks
                Samples = $samples.Count
            }
        }
        $perGpuArray = @($perGpu)
        $gpuMeans = @($perGpuArray | ForEach-Object { $_.MeanPowerWatts } | Where-Object { $null -ne $_ })
        $meanBoardPower = if ($gpuMeans.Count -eq $perGpuArray.Count) {
            [Math]::Round((($gpuMeans | Measure-Object -Sum).Sum), 3)
        }
        else { $null }
        $hardwareKey = @($perGpuArray | ForEach-Object { '{0}:{1}:{2}' -f $_.Index, $_.Model, $_.Driver }) -join '|'
        $capKey = @($perGpuArray | ForEach-Object {
            $cap = if ($null -eq $_.PowerLimitWatts) { 'null' } else { ([double]$_.PowerLimitWatts).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture) }
            '{0}:{1}' -f $_.Index, $cap
        }) -join '|'
        $clockMaximum = if ($null -eq $run.profile.graphicsClockMaximumMHz) { $null } else { [double]$run.profile.graphicsClockMaximumMHz }
        $clockKey = if ($null -eq $clockMaximum) { 'null' } else { $clockMaximum.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture) }

        [pscustomobject][ordered]@{
            RunId = [string]$run.runId
            Source = [string]$run.source
            Condition = [string]$run.condition
            ProfileLabel = [string]$run.profile.label
            ClockPolicy = [string]$run.profile.clockPolicy
            GraphicsClockMaximumMHz = $clockMaximum
            ProfileKey = '{0}|{1}|{2}|{3}' -f $run.profile.label, $run.profile.clockPolicy, $clockKey, $capKey
            HardwareKey = $hardwareKey
            Repetition = [int]$run.protocol.repetition
            Status = [string]$run.result.status
            Error = $run.result.error
            SettleSeconds = [int]$run.protocol.settleSeconds
            SampleSeconds = [int]$run.protocol.sampleSeconds
            IntervalMilliseconds = [int]$run.protocol.intervalMilliseconds
            MeanBoardPowerWatts = $meanBoardPower
            MeanUtilizationPercent = Get-CAIdleAverage -Values $allUtilization.ToArray()
            P95UtilizationPercent = Get-CAIdlePercentile -Values $allUtilization.ToArray() -Percentile 95
            MissingPowerSamples = $missingPower
            MissingUtilizationSamples = $missingUtilization
            SampleShortfall = $sampleShortfall
            PerGpu = $perGpuArray
        }
    }
    return @($rows)
}

function Test-CAIdlePowerRegression {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Runs,
        [ValidateRange(1, 100)][int]$MinimumRepetitions = 3,
        [ValidateRange(1, 3600)][int]$MinimumSampleSeconds = 30,
        [ValidateRange(0, 100)][double]$MaximumMeanUtilizationPercent = 5,
        [ValidateRange(0, 100)][double]$MaximumP95UtilizationPercent = 15,
        [ValidateRange(0, 1000)][double]$MaximumTotalIncreaseWatts = 5,
        [ValidateRange(0, 1000)][double]$MaximumTotalIncreasePercent = 10,
        [ValidateRange(0, 1000)][double]$MaximumPerGpuIncreaseWatts = 3,
        [ValidateRange(0, 1000)][double]$MaximumPerGpuIncreasePercent = 15
    )

    $rows = @(ConvertTo-CAIdlePowerRows -Runs $Runs)
    $reasons = New-Object Collections.Generic.List[string]
    $sources = @($rows | Select-Object -ExpandProperty Source -Unique)
    $fixtureOnly = $sources.Count -eq 1 -and $sources[0] -eq 'fixture'
    if ($sources.Count -ne 1) { $reasons.Add('mixed-evidence-sources') }

    $baseline = @($rows | Where-Object Condition -eq 'baseline')
    $candidate = @($rows | Where-Object Condition -eq 'candidate')
    if ($baseline.Count -lt $MinimumRepetitions -or $candidate.Count -lt $MinimumRepetitions) {
        $reasons.Add('insufficient-repetitions')
    }
    if (@($baseline | Select-Object -ExpandProperty Repetition -Unique).Count -ne $baseline.Count -or
        @($candidate | Select-Object -ExpandProperty Repetition -Unique).Count -ne $candidate.Count) {
        $reasons.Add('duplicate-repetition-number')
    }
    if (@($rows | Where-Object Status -ne 'passed').Count -gt 0) { $reasons.Add('failed-or-incomplete-run') }
    if (@($baseline | Select-Object -ExpandProperty ProfileKey -Unique).Count -ne 1 -or
        @($candidate | Select-Object -ExpandProperty ProfileKey -Unique).Count -ne 1) {
        $reasons.Add('mixed-profile-within-condition')
    }
    if ($baseline.Count -gt 0 -and @($baseline | Where-Object ClockPolicy -ne 'vendor-auto').Count -gt 0) {
        $reasons.Add('baseline-not-vendor-auto')
    }
    if ($candidate.Count -gt 0 -and @($candidate | Where-Object ClockPolicy -ne 'persistent-graphics-lock').Count -gt 0) {
        $reasons.Add('candidate-not-persistent-lock')
    }
    if ($candidate.Count -gt 0 -and @($candidate | Where-Object { $null -eq $_.GraphicsClockMaximumMHz }).Count -gt 0) {
        $reasons.Add('candidate-clock-maximum-missing')
    }
    if (@($rows | Select-Object -ExpandProperty HardwareKey -Unique).Count -ne 1) { $reasons.Add('mixed-hardware-or-driver') }
    if (@($rows | Where-Object {
        $null -eq $_.MeanBoardPowerWatts -or $_.MissingPowerSamples -gt 0 -or
        $_.MissingUtilizationSamples -gt 0 -or $_.SampleShortfall -gt 0
    }).Count -gt 0) {
        $reasons.Add('missing-or-short-telemetry')
    }
    if (@($rows | Where-Object { $_.SampleSeconds -lt $MinimumSampleSeconds }).Count -gt 0) {
        $reasons.Add('sample-window-too-short')
    }
    if (@($rows | Where-Object {
        $null -eq $_.MeanUtilizationPercent -or $null -eq $_.P95UtilizationPercent -or
        [double]$_.MeanUtilizationPercent -gt $MaximumMeanUtilizationPercent -or
        [double]$_.P95UtilizationPercent -gt $MaximumP95UtilizationPercent
    }).Count -gt 0) {
        $reasons.Add('not-idle')
    }

    $baselinePassed = @($baseline | Where-Object Status -eq 'passed')
    $candidatePassed = @($candidate | Where-Object Status -eq 'passed')
    $baselineTotal = Get-CAIdleAverage -Values @($baselinePassed | ForEach-Object { $_.MeanBoardPowerWatts })
    $candidateTotal = Get-CAIdleAverage -Values @($candidatePassed | ForEach-Object { $_.MeanBoardPowerWatts })
    $deltaWatts = $null
    $deltaPercent = $null
    $perGpuComparison = @()
    $thresholdsPass = $false
    if ($reasons.Count -eq 0 -and $null -ne $baselineTotal -and [double]$baselineTotal -gt 0 -and $null -ne $candidateTotal) {
        $deltaWatts = [Math]::Round(([double]$candidateTotal - [double]$baselineTotal), 3)
        $deltaPercent = [Math]::Round(($deltaWatts / [double]$baselineTotal) * 100.0, 3)
        $perGpu = New-Object Collections.Generic.List[object]
        foreach ($index in @($baselinePassed[0].PerGpu | Select-Object -ExpandProperty Index | Sort-Object)) {
            $baselineValues = @($baselinePassed | ForEach-Object {
                $match = @($_.PerGpu | Where-Object Index -eq $index)
                if ($match.Count -eq 1) { $match[0].MeanPowerWatts }
            })
            $candidateValues = @($candidatePassed | ForEach-Object {
                $match = @($_.PerGpu | Where-Object Index -eq $index)
                if ($match.Count -eq 1) { $match[0].MeanPowerWatts }
            })
            $baselineMean = Get-CAIdleAverage -Values $baselineValues
            $candidateMean = Get-CAIdleAverage -Values $candidateValues
            if ($null -eq $baselineMean -or [double]$baselineMean -le 0 -or $null -eq $candidateMean) {
                $reasons.Add('per-gpu-comparison-incomplete')
                continue
            }
            $gpuDelta = [Math]::Round(([double]$candidateMean - [double]$baselineMean), 3)
            $gpuDeltaPercent = [Math]::Round(($gpuDelta / [double]$baselineMean) * 100.0, 3)
            $perGpu.Add([pscustomobject][ordered]@{
                Index = [int]$index
                BaselineMeanWatts = [double]$baselineMean
                CandidateMeanWatts = [double]$candidateMean
                DeltaWatts = $gpuDelta
                DeltaPercent = $gpuDeltaPercent
                WithinThreshold = $gpuDelta -le $MaximumPerGpuIncreaseWatts -and $gpuDeltaPercent -le $MaximumPerGpuIncreasePercent
            })
        }
        $perGpuComparison = $perGpu.ToArray()
        $thresholdsPass = $reasons.Count -eq 0 -and
            $deltaWatts -le $MaximumTotalIncreaseWatts -and
            $deltaPercent -le $MaximumTotalIncreasePercent -and
            @($perGpuComparison | Where-Object { -not $_.WithinThreshold }).Count -eq 0
        if (-not $thresholdsPass -and $reasons.Count -eq 0) { $reasons.Add('idle-power-regression') }
    }
    elseif ($reasons.Count -eq 0) {
        $reasons.Add('power-comparison-incomplete')
    }

    $gateStatus = if ($fixtureOnly -and $sources.Count -eq 1) {
        'FIXTURE'
    }
    elseif ($reasons -contains 'idle-power-regression') {
        'REGRESSION'
    }
    elseif ($reasons.Count -gt 0) {
        'INSUFFICIENT'
    }
    else {
        'PASS'
    }
    $reasonCodes = @($reasons | Select-Object -Unique)
    if ($fixtureOnly) { $reasonCodes = @('fixture-source') + $reasonCodes }

    return [pscustomobject][ordered]@{
        GateStatus = $gateStatus
        CanProceedPastIdleGate = $gateStatus -eq 'PASS'
        WouldPassThresholds = [bool]$thresholdsPass
        ReasonCodes = @($reasonCodes)
        BaselineProfile = if ($baseline.Count -eq 0) { $null } else { [string]$baseline[0].ProfileLabel }
        CandidateProfile = if ($candidate.Count -eq 0) { $null } else { [string]$candidate[0].ProfileLabel }
        CandidateGraphicsClockMaximumMHz = if ($candidate.Count -eq 0) { $null } else { $candidate[0].GraphicsClockMaximumMHz }
        BaselineRepetitions = $baseline.Count
        CandidateRepetitions = $candidate.Count
        BaselineMeanBoardPowerWatts = $baselineTotal
        CandidateMeanBoardPowerWatts = $candidateTotal
        DeltaWatts = $deltaWatts
        DeltaPercent = $deltaPercent
        PerGpu = @($perGpuComparison)
        Thresholds = [pscustomobject][ordered]@{
            MinimumRepetitions = $MinimumRepetitions
            MinimumSampleSeconds = $MinimumSampleSeconds
            MaximumMeanUtilizationPercent = $MaximumMeanUtilizationPercent
            MaximumP95UtilizationPercent = $MaximumP95UtilizationPercent
            MaximumTotalIncreaseWatts = $MaximumTotalIncreaseWatts
            MaximumTotalIncreasePercent = $MaximumTotalIncreasePercent
            MaximumPerGpuIncreaseWatts = $MaximumPerGpuIncreaseWatts
            MaximumPerGpuIncreasePercent = $MaximumPerGpuIncreasePercent
        }
        HardwareWrites = $false
    }
}

function Format-CAIdleMarkdownValue {
    param($Value, [string]$Format = '0.###')

    if ($null -eq $Value) { return 'N/A' }
    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        return ([double]$Value).ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
    }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function New-CAIdlePowerGateMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Runs,
        [ValidateRange(1, 100)][int]$MinimumRepetitions = 3,
        [ValidateRange(1, 3600)][int]$MinimumSampleSeconds = 30,
        [ValidateRange(0, 100)][double]$MaximumMeanUtilizationPercent = 5,
        [ValidateRange(0, 100)][double]$MaximumP95UtilizationPercent = 15,
        [ValidateRange(0, 1000)][double]$MaximumTotalIncreaseWatts = 5,
        [ValidateRange(0, 1000)][double]$MaximumTotalIncreasePercent = 10,
        [ValidateRange(0, 1000)][double]$MaximumPerGpuIncreaseWatts = 3,
        [ValidateRange(0, 1000)][double]$MaximumPerGpuIncreasePercent = 15
    )

    $parameters = @{
        Runs = $Runs
        MinimumRepetitions = $MinimumRepetitions
        MinimumSampleSeconds = $MinimumSampleSeconds
        MaximumMeanUtilizationPercent = $MaximumMeanUtilizationPercent
        MaximumP95UtilizationPercent = $MaximumP95UtilizationPercent
        MaximumTotalIncreaseWatts = $MaximumTotalIncreaseWatts
        MaximumTotalIncreasePercent = $MaximumTotalIncreasePercent
        MaximumPerGpuIncreaseWatts = $MaximumPerGpuIncreaseWatts
        MaximumPerGpuIncreasePercent = $MaximumPerGpuIncreasePercent
    }
    $gate = Test-CAIdlePowerRegression @parameters
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# CA AutoConfig idle-power regression gate')
    $lines.Add('')
    $lines.Add(('**Gate status:** `{0}`' -f $gate.GateStatus))
    $lines.Add('')
    $lines.Add('This report is read-only. It does not change power, clock, voltage, or fan settings, and a passing idle gate alone is not a workload recommendation.')
    $lines.Add('')
    $lines.Add(('- Baseline: `{0}` ({1} repetitions; {2} W mean combined board power)' -f
        (Format-CAIdleMarkdownValue $gate.BaselineProfile),
        $gate.BaselineRepetitions,
        (Format-CAIdleMarkdownValue $gate.BaselineMeanBoardPowerWatts)))
    $lines.Add(('- Candidate: `{0}` ({1} repetitions; {2} W mean combined board power)' -f
        (Format-CAIdleMarkdownValue $gate.CandidateProfile),
        $gate.CandidateRepetitions,
        (Format-CAIdleMarkdownValue $gate.CandidateMeanBoardPowerWatts)))
    $lines.Add(('- Combined delta: `{0} W` / `{1}%`' -f
        (Format-CAIdleMarkdownValue $gate.DeltaWatts),
        (Format-CAIdleMarkdownValue $gate.DeltaPercent)))
    $lines.Add(('- Required evidence: at least {0} repetitions per condition, {1} seconds each, mean utilization <= {2}%, p95 utilization <= {3}%.' -f
        $MinimumRepetitions, $MinimumSampleSeconds,
        (Format-CAIdleMarkdownValue $MaximumMeanUtilizationPercent),
        (Format-CAIdleMarkdownValue $MaximumP95UtilizationPercent)))
    $lines.Add(('- Regression thresholds: combined <= {0} W and <= {1}%; each GPU <= {2} W and <= {3}%.' -f
        (Format-CAIdleMarkdownValue $MaximumTotalIncreaseWatts),
        (Format-CAIdleMarkdownValue $MaximumTotalIncreasePercent),
        (Format-CAIdleMarkdownValue $MaximumPerGpuIncreaseWatts),
        (Format-CAIdleMarkdownValue $MaximumPerGpuIncreasePercent)))
    $lines.Add('')
    $lines.Add('| GPU | Baseline mean W | Candidate mean W | Delta W | Delta % | Within threshold |')
    $lines.Add('| ---: | ---: | ---: | ---: | ---: | --- |')
    foreach ($gpu in @($gate.PerGpu)) {
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f
            $gpu.Index,
            (Format-CAIdleMarkdownValue $gpu.BaselineMeanWatts),
            (Format-CAIdleMarkdownValue $gpu.CandidateMeanWatts),
            (Format-CAIdleMarkdownValue $gpu.DeltaWatts),
            (Format-CAIdleMarkdownValue $gpu.DeltaPercent),
            $(if ($gpu.WithinThreshold) { 'yes' } else { 'no' })))
    }
    $lines.Add('')
    if (@($gate.ReasonCodes).Count -gt 0) {
        $lines.Add(('Reason codes: `{0}`.' -f (@($gate.ReasonCodes) -join '`, `')))
        $lines.Add('')
    }
    if ($gate.GateStatus -eq 'PASS') {
        $lines.Add('**Decision:** idle evidence permits this persistent clock-lock candidate to proceed to the separate workload, stability, temperature, and rollback gates. It is not yet an apply recommendation.')
    }
    elseif ($gate.GateStatus -eq 'REGRESSION') {
        $lines.Add('**Decision:** blocked. The persistent clock-lock candidate increased idle board power beyond at least one declared threshold.')
    }
    elseif ($gate.GateStatus -eq 'FIXTURE') {
        $lines.Add('**Decision:** fixture only. The thresholds are exercised deterministically, but synthetic data can never authorize a hardware recommendation.')
    }
    else {
        $lines.Add('**Decision:** insufficient evidence. Collect or repair the missing paired idle runs before evaluating this clock-lock candidate.')
    }
    return $lines -join "`n"
}

Export-ModuleMember -Function @(
    'Assert-CAIdlePowerRun',
    'ConvertTo-CAIdlePowerRows',
    'Test-CAIdlePowerRegression',
    'New-CAIdlePowerGateMarkdown'
)
