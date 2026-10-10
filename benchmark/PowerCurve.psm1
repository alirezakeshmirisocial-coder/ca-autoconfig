Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-CAProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        throw "Missing required property '$Path.$Name'."
    }
}

function Test-CAFiniteNumber {
    param($Value)

    if ($null -eq $Value) { return $false }
    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $false
    }
    return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
}

function Assert-CAPowerCurvePrivacy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Run)

    $forbiddenNames = @(
        'uuid', 'gpuuuid',
        'computer', 'computername', 'hostname', 'machine', 'machinename',
        'username', 'user', 'userid', 'account', 'accountname',
        'serial', 'serialnumber', 'pcibus', 'pcibusid',
        'path', 'filepath', 'directory', 'directorypath',
        'command', 'rawcommand', 'commandline'
    )

    function Visit-CAValue {
        param($Value, [string]$Path)

        if ($null -eq $Value) { return }
        if ($Value -is [string]) {
            if ($Value -match '(?i)([a-z]:\\users\\[^\\]+|/home/[^/]+|/users/[^/]+|\\\\[^\\]+\\)') {
                throw "Potential machine or user path found at '$Path'. Remove it before export."
            }
            return
        }
        if ($Value -is [ValueType]) { return }
        if ($Value -is [Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                $normalized = ([string]$key).ToLowerInvariant()
                if ($forbiddenNames -contains $normalized) {
                    throw "Sensitive field '$Path.$key' is not allowed in a benchmark export."
                }
                Visit-CAValue -Value $Value[$key] -Path "$Path.$key"
            }
            return
        }
        if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
            $index = 0
            foreach ($item in $Value) {
                Visit-CAValue -Value $item -Path "$Path[$index]"
                $index++
            }
            return
        }
        if ($Value.PSObject -and @($Value.PSObject.Properties).Count -gt 0) {
            foreach ($property in $Value.PSObject.Properties) {
                $normalized = $property.Name.ToLowerInvariant()
                if ($forbiddenNames -contains $normalized) {
                    throw "Sensitive field '$Path.$($property.Name)' is not allowed in a benchmark export."
                }
                Visit-CAValue -Value $property.Value -Path "$Path.$($property.Name)"
            }
        }
    }

    Visit-CAValue -Value $Run -Path 'run'
    return $true
}

function Assert-CAPowerCurveRun {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Run)

    foreach ($name in @('schemaVersion', 'runId', 'createdUtc', 'source', 'privacy', 'workload', 'protocol', 'result', 'gpus')) {
        Assert-CAProperty -Object $Run -Name $name -Path 'run'
    }
    $schemaVersion = [int]$Run.schemaVersion
    if ($schemaVersion -notin @(1, 2, 3)) { throw "Unsupported benchmark schema version '$($Run.schemaVersion)'." }
    if ([string]$Run.source -notin @('live', 'fixture')) { throw "Unsupported benchmark source '$($Run.source)'." }
    if ([string]::IsNullOrWhiteSpace([string]$Run.runId)) { throw 'run.runId must not be empty.' }

    foreach ($name in @('containsGpuUuid', 'containsMachineName', 'containsUserName', 'containsPaths', 'containsRawCommand')) {
        Assert-CAProperty -Object $Run.privacy -Name $name -Path 'run.privacy'
        if ([bool]$Run.privacy.$name) { throw "run.privacy.$name must be false for an exportable run." }
    }

    foreach ($name in @('class', 'name', 'model', 'quantization', 'backend')) {
        Assert-CAProperty -Object $Run.workload -Name $name -Path 'run.workload'
    }
    foreach ($name in @('warmupSeconds', 'sampleSeconds', 'intervalMilliseconds', 'repetition')) {
        Assert-CAProperty -Object $Run.protocol -Name $name -Path 'run.protocol'
    }
    if ([int]$Run.protocol.warmupSeconds -lt 0 -or [int]$Run.protocol.sampleSeconds -lt 1 -or
        [int]$Run.protocol.intervalMilliseconds -lt 250 -or [int]$Run.protocol.repetition -lt 1) {
        throw 'run.protocol contains an invalid duration, interval, or repetition.'
    }

    foreach ($name in @('status', 'throughput', 'error')) {
        Assert-CAProperty -Object $Run.result -Name $name -Path 'run.result'
    }
    if ([string]$Run.result.status -notin @('passed', 'failed', 'incomplete')) {
        throw "Unsupported result status '$($Run.result.status)'."
    }
    foreach ($name in @('promptTokensPerSecond', 'generationTokensPerSecond')) {
        Assert-CAProperty -Object $Run.result.throughput -Name $name -Path 'run.result.throughput'
        $value = $Run.result.throughput.$name
        if ($null -ne $value -and (-not (Test-CAFiniteNumber $value) -or [double]$value -le 0)) {
            throw "run.result.throughput.$name must be null or a positive finite number."
        }
    }
    $workUnitsPerSecond = $null
    if ($schemaVersion -ge 2) {
        foreach ($name in @('workUnitsPerSecond', 'workUnit')) {
            Assert-CAProperty -Object $Run.result.throughput -Name $name -Path 'run.result.throughput'
        }
        $workUnitsPerSecond = $Run.result.throughput.workUnitsPerSecond
        $workUnit = $Run.result.throughput.workUnit
        if ($null -ne $workUnitsPerSecond -and (-not (Test-CAFiniteNumber $workUnitsPerSecond) -or [double]$workUnitsPerSecond -le 0)) {
            throw 'run.result.throughput.workUnitsPerSecond must be null or a positive finite number.'
        }
        if ($null -eq $workUnitsPerSecond -and $null -ne $workUnit) {
            throw 'run.result.throughput.workUnit must be null when workUnitsPerSecond is null.'
        }
        if ($null -ne $workUnitsPerSecond -and ($null -eq $workUnit -or [string]$workUnit -notmatch '^[A-Za-z][A-Za-z0-9._-]{0,31}$')) {
            throw 'run.result.throughput.workUnit must be a safe non-empty unit when workUnitsPerSecond is present.'
        }
    }
    if ($schemaVersion -eq 3) {
        Assert-CAProperty -Object $Run -Name 'measurement' -Path 'run'
        foreach ($name in @('powerWindow', 'promptRateWindow', 'generationRateWindow', 'workRateWindow')) {
            Assert-CAProperty -Object $Run.measurement -Name $name -Path 'run.measurement'
        }
        $allowedWindows = @('steady-state', 'end-to-end-request', 'process-window', 'client-window', 'prompt-phase', 'generation-phase')
        if ([string]$Run.measurement.powerWindow -notin $allowedWindows) {
            throw 'run.measurement.powerWindow must name a supported measurement window.'
        }
        foreach ($binding in @(
            @{ Rate = 'promptTokensPerSecond'; Window = 'promptRateWindow' },
            @{ Rate = 'generationTokensPerSecond'; Window = 'generationRateWindow' },
            @{ Rate = 'workUnitsPerSecond'; Window = 'workRateWindow' }
        )) {
            $rate = $Run.result.throughput.($binding.Rate)
            $window = $Run.measurement.($binding.Window)
            if ($null -eq $rate -and $null -ne $window) {
                throw "run.measurement.$($binding.Window) must be null when $($binding.Rate) is null."
            }
            if ($null -ne $rate -and ([string]::IsNullOrWhiteSpace([string]$window) -or [string]$window -notin $allowedWindows)) {
                throw "run.measurement.$($binding.Window) must name a supported window when $($binding.Rate) is present."
            }
        }
    }
    if ([string]$Run.result.status -eq 'passed' -and
        $null -eq $Run.result.throughput.promptTokensPerSecond -and
        $null -eq $Run.result.throughput.generationTokensPerSecond -and
        $null -eq $workUnitsPerSecond) {
        throw 'A passed run must include token or work-unit throughput.'
    }

    $gpus = @($Run.gpus)
    if ($gpus.Count -lt 1) { throw 'run.gpus must contain at least one GPU.' }
    foreach ($gpu in $gpus) {
        foreach ($name in @('index', 'model', 'driver', 'powerLimitWatts', 'samples')) {
            Assert-CAProperty -Object $gpu -Name $name -Path 'run.gpus[]'
        }
        if ($null -ne $gpu.powerLimitWatts -and (-not (Test-CAFiniteNumber $gpu.powerLimitWatts) -or [double]$gpu.powerLimitWatts -le 0)) {
            throw 'run.gpus[].powerLimitWatts must be null or a positive finite number.'
        }
        $samples = @($gpu.samples)
        if ($samples.Count -lt 1) { throw 'Every GPU needs at least one telemetry sample.' }
        foreach ($sample in $samples) {
            foreach ($name in @('elapsedMilliseconds', 'powerDrawWatts', 'temperatureC', 'utilizationPercent', 'memoryUsedMiB', 'memoryTotalMiB', 'graphicsClockMHz')) {
                Assert-CAProperty -Object $sample -Name $name -Path 'run.gpus[].samples[]'
            }
            if (-not (Test-CAFiniteNumber $sample.elapsedMilliseconds) -or [double]$sample.elapsedMilliseconds -lt 0) {
                throw 'Sample elapsedMilliseconds must be a non-negative finite number.'
            }
            foreach ($name in @('powerDrawWatts', 'temperatureC', 'utilizationPercent', 'memoryUsedMiB', 'memoryTotalMiB', 'graphicsClockMHz')) {
                $value = $sample.$name
                if ($null -ne $value -and -not (Test-CAFiniteNumber $value)) {
                    throw "Sample $name must be null or finite."
                }
            }
        }
    }

    Assert-CAPowerCurvePrivacy -Run $Run | Out-Null
    return $Run
}

function Get-CAAverage {
    param([object[]]$Values)

    $finite = @($Values | Where-Object { Test-CAFiniteNumber $_ } | ForEach-Object { [double]$_ })
    if ($finite.Count -eq 0) { return $null }
    return [Math]::Round((($finite | Measure-Object -Average).Average), 3)
}

function Format-CAProfile {
    param([object[]]$Gpus)

    $parts = foreach ($gpu in @($Gpus | Sort-Object { [int]$_.index })) {
        $cap = if ($null -eq $gpu.powerLimitWatts) { '?' } else { ([double]$gpu.powerLimitWatts).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture) }
        "GPU$([int]$gpu.index) ${cap} W"
    }
    return $parts -join ' + '
}

function ConvertTo-CAPowerCurveRows {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Runs)

    $rows = foreach ($run in @($Runs)) {
        Assert-CAPowerCurveRun -Run $run | Out-Null
        $gpuMeans = @()
        $temperatures = @()
        $missingPower = 0
        $sampleCount = 0
        foreach ($gpu in @($run.gpus)) {
            $samples = @($gpu.samples)
            $sampleCount += $samples.Count
            $powerValues = @($samples | ForEach-Object { $_.powerDrawWatts } | Where-Object { $null -ne $_ })
            $missingPower += $samples.Count - $powerValues.Count
            $mean = Get-CAAverage -Values $powerValues
            if ($null -ne $mean) { $gpuMeans += [double]$mean }
            $temperatures += @($samples | ForEach-Object { $_.temperatureC } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
        }

        $meanPower = if ($gpuMeans.Count -eq @($run.gpus).Count) { [Math]::Round((($gpuMeans | Measure-Object -Sum).Sum), 3) } else { $null }
        $peakTemperature = if ($temperatures.Count) { [Math]::Round((($temperatures | Measure-Object -Maximum).Maximum), 3) } else { $null }
        $generation = if ($null -eq $run.result.throughput.generationTokensPerSecond) { $null } else { [double]$run.result.throughput.generationTokensPerSecond }
        $prompt = if ($null -eq $run.result.throughput.promptTokensPerSecond) { $null } else { [double]$run.result.throughput.promptTokensPerSecond }
        $workRate = if ([int]$run.schemaVersion -ge 2 -and $null -ne $run.result.throughput.workUnitsPerSecond) { [double]$run.result.throughput.workUnitsPerSecond } else { $null }
        $workUnit = if ([int]$run.schemaVersion -ge 2 -and $null -ne $run.result.throughput.workUnit) { [string]$run.result.throughput.workUnit } else { $null }
        $powerWindow = if ([int]$run.schemaVersion -eq 3) { [string]$run.measurement.powerWindow } else { 'legacy-unspecified' }
        $promptRateWindow = if ([int]$run.schemaVersion -eq 3 -and $null -ne $run.measurement.promptRateWindow) { [string]$run.measurement.promptRateWindow } else { $null }
        $generationRateWindow = if ([int]$run.schemaVersion -eq 3 -and $null -ne $run.measurement.generationRateWindow) { [string]$run.measurement.generationRateWindow } else { $null }
        $workRateWindow = if ([int]$run.schemaVersion -eq 3 -and $null -ne $run.measurement.workRateWindow) { [string]$run.measurement.workRateWindow } else { $null }
        $generationRatePowerIndex = if ($null -ne $generation -and $null -ne $meanPower -and $meanPower -gt 0) {
            [Math]::Round($generation / $meanPower, 6)
        } else { $null }
        $workRatePowerIndex = if ($null -ne $workRate -and $null -ne $meanPower -and $meanPower -gt 0) {
            [Math]::Round($workRate / $meanPower, 9)
        } else { $null }
        $generationAligned = $null -ne $generationRatePowerIndex -and $powerWindow -eq $generationRateWindow
        $workAligned = $null -ne $workRatePowerIndex -and $powerWindow -eq $workRateWindow
        $efficiency = if ($generationAligned) { $generationRatePowerIndex } else { $null }
        $workEfficiency = if ($workAligned) { $workRatePowerIndex } else { $null }

        [pscustomobject][ordered]@{
            RunId = [string]$run.runId
            WorkloadKey = @([string]$run.workload.class, [string]$run.workload.name, [string]$run.workload.model, [string]$run.workload.quantization, [string]$run.workload.backend, [string]$workUnit) -join '|'
            Workload = [string]$run.workload.name
            Profile = Format-CAProfile -Gpus @($run.gpus)
            Repetition = [int]$run.protocol.repetition
            Status = [string]$run.result.status
            PromptTokensPerSecond = $prompt
            GenerationTokensPerSecond = $generation
            WorkUnitsPerSecond = $workRate
            WorkUnit = $workUnit
            PowerWindow = $powerWindow
            PromptRateWindow = $promptRateWindow
            GenerationRateWindow = $generationRateWindow
            WorkRateWindow = $workRateWindow
            MeanBoardPowerWatts = $meanPower
            PeakTemperatureC = $peakTemperature
            GenerationRatePerWindowWatt = $generationRatePowerIndex
            WorkRatePerWindowWatt = $workRatePowerIndex
            GenerationEnergyAligned = $generationAligned
            WorkEnergyAligned = $workAligned
            GenerationTokensPerJoule = $efficiency
            WorkUnitsPerJoule = $workEfficiency
            SampleCount = $sampleCount
            MissingPowerSamples = $missingPower
        }
    }
    return @($rows)
}

function Format-CAMarkdownValue {
    param($Value, [string]$Format = '0.###')

    if ($null -eq $Value) { return 'N/A' }
    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        return ([double]$Value).ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
    }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function New-CAPowerCurveMarkdown {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Runs)

    $rows = @(ConvertTo-CAPowerCurveRows -Runs $Runs)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# CA AutoConfig power-curve report')
    $lines.Add('')
    $lines.Add("Runs analyzed: $($rows.Count). Values are measured only for the listed hardware, workload, settings, and protocol.")
    $lines.Add('')
    $lines.Add('A measured efficiency leader is not a universal recommendation. Board limits, cooling, drivers, model shape, quantization, context, batching, and workload phase can change the result.')
    $lines.Add('')
    $lines.Add('Exact per-joule metrics appear only when the throughput rate and board-power samples cover the same declared window. Otherwise the report keeps a rate/window-W index for within-protocol comparison and does not call it energy per unit.')
    $lines.Add('')
    $lines.Add('| Run | Power profile | Status | Prompt tok/s | Generation tok/s | Work rate | Unit | Power window | Generation window | Work window | Mean board W | Peak C | Generation rate/W index | Aligned generation tok/J | Work rate/W index | Aligned work/J | Missing power samples |')
    $lines.Add('| --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
    foreach ($row in $rows) {
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} | {13} | {14} | {15} | {16} |' -f
            (Format-CAMarkdownValue $row.RunId),
            (Format-CAMarkdownValue $row.Profile),
            (Format-CAMarkdownValue $row.Status),
            (Format-CAMarkdownValue $row.PromptTokensPerSecond),
            (Format-CAMarkdownValue $row.GenerationTokensPerSecond),
            (Format-CAMarkdownValue $row.WorkUnitsPerSecond),
            (Format-CAMarkdownValue $row.WorkUnit),
            (Format-CAMarkdownValue $row.PowerWindow),
            (Format-CAMarkdownValue $row.GenerationRateWindow),
            (Format-CAMarkdownValue $row.WorkRateWindow),
            (Format-CAMarkdownValue $row.MeanBoardPowerWatts),
            (Format-CAMarkdownValue $row.PeakTemperatureC),
            (Format-CAMarkdownValue $row.GenerationRatePerWindowWatt '0.000000'),
            (Format-CAMarkdownValue $row.GenerationTokensPerJoule '0.000000'),
            (Format-CAMarkdownValue $row.WorkRatePerWindowWatt '0.000000000'),
            (Format-CAMarkdownValue $row.WorkUnitsPerJoule '0.000000000'),
            $row.MissingPowerSamples))
    }

    $lines.Add('')
    $lines.Add('## Within-workload observations')
    $lines.Add('')
    foreach ($group in @($rows | Group-Object WorkloadKey | Sort-Object Name)) {
        $generationComparable = @($group.Group | Where-Object {
            $_.Status -eq 'passed' -and $null -ne $_.GenerationRatePerWindowWatt
        } | Sort-Object GenerationRatePerWindowWatt -Descending)
        $alignedGeneration = @($generationComparable | Where-Object GenerationEnergyAligned)
        $workComparable = @($group.Group | Where-Object {
            $_.Status -eq 'passed' -and $null -ne $_.WorkRatePerWindowWatt -and $null -ne $_.WorkUnit
        } | Sort-Object WorkRatePerWindowWatt -Descending)
        $alignedWork = @($workComparable | Where-Object WorkEnergyAligned)
        $workloadName = [string]$group.Group[0].Workload
        if ($generationComparable.Count -ge 2 -and $alignedGeneration.Count -eq $generationComparable.Count) {
            $best = $alignedGeneration | Sort-Object GenerationTokensPerJoule -Descending | Select-Object -First 1
            $lines.Add(('- **{0}:** highest measured generation efficiency in this dataset was `{1}` at `{2}` tokens/J. Treat it as a candidate for repetition, not a universal best limit.' -f
                (Format-CAMarkdownValue $workloadName),
                (Format-CAMarkdownValue $best.Profile),
                (Format-CAMarkdownValue $best.GenerationTokensPerJoule '0.000000')))
        }
        elseif ($generationComparable.Count -ge 2) {
            $best = $generationComparable[0]
            $powerWindows = @($generationComparable | Select-Object -ExpandProperty PowerWindow -Unique) -join ', '
            $rateWindows = @($generationComparable | Select-Object -ExpandProperty GenerationRateWindow -Unique) -join ', '
            $lines.Add(('- **{0}:** highest generation rate/power index was `{1}` at `{2}` tok/s/W (power window: `{3}`; rate window: `{4}`). The windows are not energy-aligned, so this is not tokens/J or an energy recommendation.' -f
                (Format-CAMarkdownValue $workloadName),
                (Format-CAMarkdownValue $best.Profile),
                (Format-CAMarkdownValue $best.GenerationRatePerWindowWatt '0.000000'),
                (Format-CAMarkdownValue $powerWindows),
                (Format-CAMarkdownValue $rateWindows)))
        }
        elseif ($workComparable.Count -ge 2 -and $alignedWork.Count -eq $workComparable.Count) {
            $best = $alignedWork | Sort-Object WorkUnitsPerJoule -Descending | Select-Object -First 1
            $unit = [string]$best.WorkUnit
            $lines.Add(('- **{0}:** highest measured {1} efficiency in this dataset was `{2}` at `{3}` {1}/J. Treat it as a candidate for repetition, not a universal best limit.' -f
                (Format-CAMarkdownValue $workloadName),
                (Format-CAMarkdownValue $unit),
                (Format-CAMarkdownValue $best.Profile),
                (Format-CAMarkdownValue $best.WorkUnitsPerJoule '0.000000000')))
        }
        elseif ($workComparable.Count -ge 2) {
            $best = $workComparable[0]
            $unit = [string]$best.WorkUnit
            $powerWindows = @($workComparable | Select-Object -ExpandProperty PowerWindow -Unique) -join ', '
            $rateWindows = @($workComparable | Select-Object -ExpandProperty WorkRateWindow -Unique) -join ', '
            $lines.Add(('- **{0}:** highest {1} rate/power index was `{2}` at `{3}` {1}/s/W (power window: `{4}`; rate window: `{5}`). The windows are not energy-aligned, so this is not {1}/J or an energy recommendation.' -f
                (Format-CAMarkdownValue $workloadName),
                (Format-CAMarkdownValue $unit),
                (Format-CAMarkdownValue $best.Profile),
                (Format-CAMarkdownValue $best.WorkRatePerWindowWatt '0.000000000'),
                (Format-CAMarkdownValue $powerWindows),
                (Format-CAMarkdownValue $rateWindows)))
        }
        else {
            $lines.Add("- **$(Format-CAMarkdownValue $workloadName):** fewer than two comparable passed runs; no efficiency leader is reported.")
        }
    }

    $lines.Add('')
    $lines.Add('Generated from schema-v1/v2/v3 anonymized exports. Legacy schemas have unspecified phase provenance, so they do not produce exact per-joule metrics. `N/A` is retained as missing evidence rather than converted to zero.')
    return $lines -join "`n"
}

function ConvertTo-CASvgText {
    param($Value, [int]$MaximumLength = 120)

    $text = if ($null -eq $Value) { 'unknown' } else { [string]$Value }
    $text = $text.Replace("`r", ' ').Replace("`n", ' ').Trim()
    if ($text.Length -gt $MaximumLength) { $text = $text.Substring(0, $MaximumLength - 3) + '...' }
    return [Security.SecurityElement]::Escape($text)
}

function Format-CASvgNumber {
    param([double]$Value, [string]$Format = '0.###')
    return $Value.ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}

function New-CAPowerCurveCardSvg {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Runs)

    $runsArray = @($Runs)
    if ($runsArray.Count -lt 2) { throw 'A power-curve card requires at least two run exports.' }
    $rows = @(ConvertTo-CAPowerCurveRows -Runs $runsArray)
    $workloadKeys = @($rows | Select-Object -ExpandProperty WorkloadKey -Unique)
    if ($workloadKeys.Count -ne 1) { throw 'A power-curve card can contain only one exact workload fingerprint.' }
    $sources = @($runsArray | ForEach-Object { [string]$_.source } | Select-Object -Unique)
    if ($sources.Count -ne 1) { throw 'A power-curve card cannot mix live and fixture sources.' }

    $tokenRows = @($rows | Where-Object { $_.Status -eq 'passed' -and $null -ne $_.GenerationTokensPerSecond })
    $workRows = @($rows | Where-Object { $_.Status -eq 'passed' -and $null -ne $_.WorkUnitsPerSecond })
    if ($tokenRows.Count -gt 0 -and $workRows.Count -gt 0) { throw 'A power-curve card cannot mix token and work-unit throughput.' }
    if ($tokenRows.Count -eq 0 -and $workRows.Count -eq 0) { throw 'A power-curve card requires passed throughput evidence.' }

    $isToken = $tokenRows.Count -gt 0
    $workUnits = @($workRows | Select-Object -ExpandProperty WorkUnit -Unique)
    if (-not $isToken -and $workUnits.Count -ne 1) { throw 'A power-curve card requires one exact work unit.' }
    $metricRows = if ($isToken) { $tokenRows } else { $workRows }
    $phaseKeys = @($metricRows | ForEach-Object {
        $rateWindow = if ($isToken) { $_.GenerationRateWindow } else { $_.WorkRateWindow }
        '{0}|{1}' -f $_.PowerWindow, $rateWindow
    } | Select-Object -Unique)
    if ($phaseKeys.Count -ne 1) { throw 'A power-curve card requires one exact power/rate window provenance.' }
    $powerWindow = [string]$metricRows[0].PowerWindow
    $rateWindow = if ($isToken) { [string]$metricRows[0].GenerationRateWindow } else { [string]$metricRows[0].WorkRateWindow }
    $energyAligned = if ($isToken) {
        @($metricRows | Where-Object GenerationEnergyAligned).Count -eq $metricRows.Count
    }
    else {
        @($metricRows | Where-Object WorkEnergyAligned).Count -eq $metricRows.Count
    }
    $rateLabel = if ($isToken) { 'generation tok/s' } else { ([string]$workUnits[0]) + '/s' }
    $efficiencyLabel = if ($energyAligned) {
        if ($isToken) { 'tokens/J' } else { ([string]$workUnits[0]) + '/J' }
    }
    else {
        if ($isToken) { 'generation rate/W index' } else { ([string]$workUnits[0]) + '/s/W index' }
    }

    $profiles = New-Object Collections.Generic.List[object]
    foreach ($group in @($rows | Group-Object Profile | Sort-Object Name)) {
        $comparable = @($group.Group | Where-Object {
            $_.Status -eq 'passed' -and $null -ne $_.MeanBoardPowerWatts -and
            (($isToken -and $null -ne $_.GenerationTokensPerSecond) -or (-not $isToken -and $null -ne $_.WorkUnitsPerSecond))
        })
        if ($comparable.Count -eq 0) { continue }
        $meanPower = Get-CAAverage -Values @($comparable | ForEach-Object { $_.MeanBoardPowerWatts })
        $meanRate = Get-CAAverage -Values @($comparable | ForEach-Object { if ($isToken) { $_.GenerationTokensPerSecond } else { $_.WorkUnitsPerSecond } })
        $peakValues = @($comparable | ForEach-Object { $_.PeakTemperatureC } | Where-Object { $null -ne $_ })
        $peak = if ($peakValues.Count) { [double](($peakValues | Measure-Object -Maximum).Maximum) } else { $null }
        $profiles.Add([pscustomobject][ordered]@{
            Name = [string]$group.Name
            MeanPower = [double]$meanPower
            MeanRate = [double]$meanRate
            Efficiency = [double]$meanRate / [double]$meanPower
            PeakTemperature = $peak
            TotalRuns = @($group.Group).Count
            PassedRuns = @($group.Group | Where-Object Status -eq 'passed').Count
            FailedRuns = @($group.Group | Where-Object Status -ne 'passed').Count
        })
    }
    if ($profiles.Count -lt 2) { throw 'A power-curve card requires at least two comparable power profiles.' }

    $profileArray = @($profiles | Sort-Object MeanPower)
    $leader = @($profileArray | Sort-Object Efficiency -Descending)[0]
    $source = [string]$sources[0]
    $minimumRepetitions = [int](($profileArray | Measure-Object -Property TotalRuns -Minimum).Minimum)
    $publishable = $source -eq 'live' -and $minimumRepetitions -ge 3
    $evidenceLabel = if ($source -eq 'fixture') {
        'FIXTURE / NOT HARDWARE EVIDENCE'
    }
    elseif ($publishable -and $energyAligned) {
        'MEASURED / ENERGY-ALIGNED'
    }
    elseif ($publishable) {
        'MEASURED / RATE-POWER INDEX'
    }
    else {
        'DRAFT / INSUFFICIENT REPETITIONS'
    }
    $evidenceDetail = if ($source -eq 'fixture') {
        'Synthetic data exercises the pipeline only'
    }
    elseif ($publishable -and $energyAligned) {
        'Same-window throughput and board power; local protocol only'
    }
    elseif ($publishable) {
        "Power: $powerWindow / rate: $rateWindow"
    }
    else {
        'Live export, but fewer than 3 runs exist for at least one profile'
    }

    $workload = $runsArray[0].workload
    $title = ConvertTo-CASvgText $workload.name 56
    $subtitle = ConvertTo-CASvgText (('{0} / {1} / {2}' -f $workload.model, $workload.quantization, $workload.backend)) 88
    $totalFailed = [int](($profileArray | Measure-Object -Property FailedRuns -Sum).Sum)
    $runCount = $rows.Count
    $candidateHeading = if ($source -eq 'fixture' -and $energyAligned) { 'SYNTHETIC EFFICIENCY EXAMPLE' } elseif ($source -eq 'fixture') { 'SYNTHETIC RATE / POWER EXAMPLE' } elseif ($publishable -and $energyAligned) { 'EFFICIENCY CANDIDATE' } elseif ($publishable) { 'RATE / POWER CANDIDATE' } elseif ($energyAligned) { 'PROVISIONAL CANDIDATE' } else { 'PROVISIONAL RATE / POWER' }
    $candidateAction = if ($source -eq 'fixture') { 'PIPELINE EXAMPLE ONLY' } elseif (-not $energyAligned) { 'ALIGN PHASES FOR ENERGY CLAIM' } elseif ($publishable) { 'REPEAT BEFORE APPLYING' } else { 'COLLECT MORE REPETITIONS' }
    $candidateBoundary = if ($source -eq 'fixture') {
        'Synthetic fixture leader, not a hardware result.'
    }
    elseif ($publishable -and $energyAligned) {
        'Measured leader, not a universal limit.'
    }
    elseif ($publishable) {
        'Measured index leader; not joules or a hardware limit.'
    }
    elseif (-not $energyAligned) {
        'Draft index leader; power and rate windows differ.'
    }
    else {
        'Live draft leader, not a hardware recommendation.'
    }

    $profileDescriptions = foreach ($profile in $profileArray) {
        '{0}: {1} W mean combined board power, {2} {3}, {4} of {5} runs passed' -f
            $profile.Name,
            (Format-CASvgNumber $profile.MeanPower '0.###'),
            (Format-CASvgNumber $profile.MeanRate '0.###'),
            $rateLabel,
            $profile.PassedRuns,
            $profile.TotalRuns
    }
    $accessibleDescription = '{0}. {1}. Power window: {2}. Rate window: {3}. Energy aligned: {4}. {5} runs, {6} profiles, {7} failed or incomplete. Axes compare {8} against mean combined board power in watts. {9}. {10} Selected profile: {11}. Exact anonymized raw JSON and method are required; this is not a universal recommendation.' -f
        $evidenceLabel,
        $evidenceDetail,
        $powerWindow,
        $rateWindow,
        $energyAligned,
        $runCount,
        $profileArray.Count,
        $totalFailed,
        $rateLabel,
        ($profileDescriptions -join '; '),
        $candidateBoundary,
        $leader.Name

    $minimumPower = [double](($profileArray | Measure-Object -Property MeanPower -Minimum).Minimum)
    $maximumPower = [double](($profileArray | Measure-Object -Property MeanPower -Maximum).Maximum)
    $minimumRate = [double](($profileArray | Measure-Object -Property MeanRate -Minimum).Minimum)
    $maximumRate = [double](($profileArray | Measure-Object -Property MeanRate -Maximum).Maximum)
    $powerSpan = [Math]::Max(1.0, $maximumPower - $minimumPower)
    $rateSpan = [Math]::Max(0.001, $maximumRate - $minimumRate)
    $axisPowerMin = [Math]::Max(0.0, $minimumPower - $powerSpan * 0.18)
    $axisPowerMax = $maximumPower + $powerSpan * 0.18
    $axisRateMin = [Math]::Max(0.0, $minimumRate - $rateSpan * 0.35)
    $axisRateMax = $maximumRate + $rateSpan * 0.35
    $plotLeft = 72.0; $plotRight = 790.0; $plotTop = 218.0; $plotBottom = 520.0
    $plotWidth = $plotRight - $plotLeft; $plotHeight = $plotBottom - $plotTop

    $svg = New-Object Text.StringBuilder
    $null = $svg.AppendLine('<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="675" viewBox="0 0 1200 675" role="img" aria-labelledby="title description">')
    $null = $svg.AppendLine(('  <title id="title">CA AutoConfig power curve - {0}</title>' -f $title))
    $null = $svg.AppendLine(('  <desc id="description">{0}</desc>' -f (ConvertTo-CASvgText $accessibleDescription 1200)))
    $null = $svg.AppendLine('  <rect width="1200" height="675" fill="#0A0F14"/>')
    $accent = if ($source -eq 'fixture') { '#F6C177' } elseif ($publishable -and $energyAligned) { '#5CE0A7' } else { '#E8A65D' }
    $null = $svg.AppendLine(('  <rect width="1200" height="7" fill="{0}"/>' -f $accent))
    $null = $svg.AppendLine(('  <rect x="850" y="28" width="286" height="42" rx="8" fill="#171D25" stroke="{0}"/>' -f $accent))
    $null = $svg.AppendLine(('  <text x="993" y="55" text-anchor="middle" fill="{0}" font-family="Segoe UI,Arial,sans-serif" font-size="14" font-weight="700">{1}</text>' -f $accent, (ConvertTo-CASvgText $evidenceLabel)))
    $null = $svg.AppendLine(('  <text x="64" y="92" fill="#F2F5F8" font-family="Segoe UI,Arial,sans-serif" font-size="40" font-weight="700">{0}</text>' -f $title))
    $null = $svg.AppendLine(('  <text x="64" y="132" fill="#A6B1BE" font-family="Segoe UI,Arial,sans-serif" font-size="17">{0}</text>' -f $subtitle))
    $null = $svg.AppendLine(('  <text x="64" y="169" fill="#7F8C9C" font-family="Segoe UI,Arial,sans-serif" font-size="13">{0} runs / {1} profiles / {2} failed or incomplete</text>' -f $runCount, $profileArray.Count, $totalFailed))

    for ($index = 0; $index -le 4; $index++) {
        $ratio = $index / 4.0
        $x = $plotLeft + $plotWidth * $ratio
        $y = $plotBottom - $plotHeight * $ratio
        $powerValue = $axisPowerMin + ($axisPowerMax - $axisPowerMin) * $ratio
        $rateValue = $axisRateMin + ($axisRateMax - $axisRateMin) * $ratio
        $null = $svg.AppendLine(('  <line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="#26303B" stroke-width="1"/>' -f (Format-CASvgNumber $x), (Format-CASvgNumber $plotTop), (Format-CASvgNumber $plotBottom)))
        $null = $svg.AppendLine(('  <line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#26303B" stroke-width="1"/>' -f (Format-CASvgNumber $plotLeft), (Format-CASvgNumber $y), (Format-CASvgNumber $plotRight)))
        $null = $svg.AppendLine(('  <text x="{0}" y="548" text-anchor="middle" fill="#7F8C9C" font-family="Segoe UI,Arial,sans-serif" font-size="12">{1}</text>' -f (Format-CASvgNumber $x), (Format-CASvgNumber $powerValue '0')))
        $null = $svg.AppendLine(('  <text x="58" y="{0}" text-anchor="end" dominant-baseline="middle" fill="#7F8C9C" font-family="Segoe UI,Arial,sans-serif" font-size="12">{1}</text>' -f (Format-CASvgNumber $y), (Format-CASvgNumber $rateValue '0.###')))
    }
    $null = $svg.AppendLine('  <text x="431" y="580" text-anchor="middle" fill="#A6B1BE" font-family="Segoe UI,Arial,sans-serif" font-size="14">Mean combined board power (W)</text>')
    $null = $svg.AppendLine(('  <text x="18" y="370" text-anchor="middle" transform="rotate(-90 18 370)" fill="#A6B1BE" font-family="Segoe UI,Arial,sans-serif" font-size="14">{0}</text>' -f (ConvertTo-CASvgText $rateLabel)))

    $pointCoordinates = New-Object Collections.Generic.List[string]
    foreach ($profile in $profileArray) {
        $x = $plotLeft + (($profile.MeanPower - $axisPowerMin) / ($axisPowerMax - $axisPowerMin)) * $plotWidth
        $y = $plotBottom - (($profile.MeanRate - $axisRateMin) / ($axisRateMax - $axisRateMin)) * $plotHeight
        $pointCoordinates.Add(('{0},{1}' -f (Format-CASvgNumber $x), (Format-CASvgNumber $y)))
    }
    $null = $svg.AppendLine(('  <polyline points="{0}" fill="none" stroke="#64B8E0" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>' -f ($pointCoordinates -join ' ')))
    foreach ($profile in $profileArray) {
        $x = $plotLeft + (($profile.MeanPower - $axisPowerMin) / ($axisPowerMax - $axisPowerMin)) * $plotWidth
        $y = $plotBottom - (($profile.MeanRate - $axisRateMin) / ($axisRateMax - $axisRateMin)) * $plotHeight
        $isLeader = [Object]::ReferenceEquals($profile, $leader) -or $profile.Name -eq $leader.Name
        $fill = if ($isLeader) { '#5CE0A7' } else { '#64B8E0' }
        $null = $svg.AppendLine(('  <circle cx="{0}" cy="{1}" r="9" fill="{2}" stroke="#0A0F14" stroke-width="4"/>' -f (Format-CASvgNumber $x), (Format-CASvgNumber $y), $fill))
        $labelY = $y + 30
        $null = $svg.AppendLine(('  <text x="{0}" y="{1}" text-anchor="middle" fill="#DCE4EC" font-family="Segoe UI,Arial,sans-serif" font-size="12" font-weight="600">{2}</text>' -f (Format-CASvgNumber $x), (Format-CASvgNumber $labelY), (ConvertTo-CASvgText $profile.Name 44)))
        $null = $svg.AppendLine(('  <text x="{0}" y="{1}" text-anchor="middle" fill="#7F8C9C" font-family="Segoe UI,Arial,sans-serif" font-size="11">{2}/{3} passed</text>' -f (Format-CASvgNumber $x), (Format-CASvgNumber ($labelY + 17)), $profile.PassedRuns, $profile.TotalRuns))
    }

    $null = $svg.AppendLine('  <line x1="830" y1="205" x2="830" y2="572" stroke="#33404D"/>')
    $null = $svg.AppendLine(('  <text x="864" y="234" fill="#A6B1BE" font-family="Segoe UI,Arial,sans-serif" font-size="13" font-weight="700">{0}</text>' -f (ConvertTo-CASvgText $candidateHeading)))
    $null = $svg.AppendLine(('  <text x="864" y="277" fill="#F2F5F8" font-family="Segoe UI,Arial,sans-serif" font-size="21" font-weight="700">{0}</text>' -f (ConvertTo-CASvgText $leader.Name 32)))
    $null = $svg.AppendLine(('  <text x="864" y="327" fill="#5CE0A7" font-family="Segoe UI,Arial,sans-serif" font-size="36" font-weight="700">{0}</text>' -f (Format-CASvgNumber $leader.Efficiency '0.000000')))
    $null = $svg.AppendLine(('  <text x="864" y="351" fill="#A6B1BE" font-family="Segoe UI,Arial,sans-serif" font-size="14">{0}</text>' -f (ConvertTo-CASvgText $efficiencyLabel)))
    $null = $svg.AppendLine(('  <text x="864" y="402" fill="#DCE4EC" font-family="Segoe UI,Arial,sans-serif" font-size="17">{0} {1}</text>' -f (Format-CASvgNumber $leader.MeanRate '0.###'), (ConvertTo-CASvgText $rateLabel)))
    $null = $svg.AppendLine(('  <text x="864" y="433" fill="#DCE4EC" font-family="Segoe UI,Arial,sans-serif" font-size="17">{0} W mean board power</text>' -f (Format-CASvgNumber $leader.MeanPower '0.###')))
    $temperatureText = if ($null -eq $leader.PeakTemperature) { 'N/A peak temperature' } else { (Format-CASvgNumber ([double]$leader.PeakTemperature) '0.#') + ' C peak temperature' }
    $null = $svg.AppendLine(('  <text x="864" y="464" fill="#DCE4EC" font-family="Segoe UI,Arial,sans-serif" font-size="17">{0}</text>' -f (ConvertTo-CASvgText $temperatureText)))
    $null = $svg.AppendLine(('  <text x="864" y="510" fill="#F6C177" font-family="Segoe UI,Arial,sans-serif" font-size="14" font-weight="700">{0}</text>' -f (ConvertTo-CASvgText $candidateAction)))
    $null = $svg.AppendLine(('  <text x="864" y="535" fill="#A6B1BE" font-family="Segoe UI,Arial,sans-serif" font-size="13">{0}</text>' -f (ConvertTo-CASvgText $candidateBoundary)))
    $null = $svg.AppendLine(('  <text x="864" y="558" fill="#7F8C9C" font-family="Segoe UI,Arial,sans-serif" font-size="12">{0}</text>' -f (ConvertTo-CASvgText $evidenceDetail 56)))
    $null = $svg.AppendLine('  <line x1="64" y1="612" x2="1136" y2="612" stroke="#33404D"/>')
    $null = $svg.AppendLine('  <text x="64" y="644" fill="#7F8C9C" font-family="Segoe UI,Arial,sans-serif" font-size="13">Share with exact anonymized raw JSON + method / failures retained / N/A stays missing</text>')
    $null = $svg.AppendLine('  <text x="1136" y="644" text-anchor="end" fill="#A6B1BE" font-family="Segoe UI,Arial,sans-serif" font-size="13">CA AutoConfig / github.com/alirezakeshmirisocial-coder/ca-autoconfig</text>')
    $null = $svg.AppendLine('</svg>')
    return $svg.ToString()
}

Export-ModuleMember -Function @(
    'Assert-CAPowerCurvePrivacy',
    'Assert-CAPowerCurveRun',
    'ConvertTo-CAPowerCurveRows',
    'New-CAPowerCurveMarkdown',
    'New-CAPowerCurveCardSvg'
)
