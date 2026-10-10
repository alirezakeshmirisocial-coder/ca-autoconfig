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
        'uuid', 'computer', 'hostname', 'machine', 'username', 'user',
        'serial', 'pcibusid', 'path', 'command', 'commandline'
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
    if ($schemaVersion -notin @(1, 2)) { throw "Unsupported benchmark schema version '$($Run.schemaVersion)'." }
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
    if ($schemaVersion -eq 2) {
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
        $workRate = if ([int]$run.schemaVersion -eq 2 -and $null -ne $run.result.throughput.workUnitsPerSecond) { [double]$run.result.throughput.workUnitsPerSecond } else { $null }
        $workUnit = if ([int]$run.schemaVersion -eq 2 -and $null -ne $run.result.throughput.workUnit) { [string]$run.result.throughput.workUnit } else { $null }
        $efficiency = if ($null -ne $generation -and $null -ne $meanPower -and $meanPower -gt 0) {
            [Math]::Round($generation / $meanPower, 6)
        } else { $null }
        $workEfficiency = if ($null -ne $workRate -and $null -ne $meanPower -and $meanPower -gt 0) {
            [Math]::Round($workRate / $meanPower, 9)
        } else { $null }

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
            MeanBoardPowerWatts = $meanPower
            PeakTemperatureC = $peakTemperature
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
    $lines.Add('| Run | Power profile | Status | Prompt tok/s | Generation tok/s | Work rate | Unit | Mean board W | Peak °C | Generation tok/J | Work/J | Missing power samples |')
    $lines.Add('| --- | --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |')
    foreach ($row in $rows) {
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} |' -f
            (Format-CAMarkdownValue $row.RunId),
            (Format-CAMarkdownValue $row.Profile),
            (Format-CAMarkdownValue $row.Status),
            (Format-CAMarkdownValue $row.PromptTokensPerSecond),
            (Format-CAMarkdownValue $row.GenerationTokensPerSecond),
            (Format-CAMarkdownValue $row.WorkUnitsPerSecond),
            (Format-CAMarkdownValue $row.WorkUnit),
            (Format-CAMarkdownValue $row.MeanBoardPowerWatts),
            (Format-CAMarkdownValue $row.PeakTemperatureC),
            (Format-CAMarkdownValue $row.GenerationTokensPerJoule '0.000000'),
            (Format-CAMarkdownValue $row.WorkUnitsPerJoule '0.000000000'),
            $row.MissingPowerSamples))
    }

    $lines.Add('')
    $lines.Add('## Within-workload observations')
    $lines.Add('')
    foreach ($group in @($rows | Group-Object WorkloadKey | Sort-Object Name)) {
        $comparable = @($group.Group | Where-Object {
            $_.Status -eq 'passed' -and $null -ne $_.GenerationTokensPerJoule
        } | Sort-Object GenerationTokensPerJoule -Descending)
        $workComparable = @($group.Group | Where-Object {
            $_.Status -eq 'passed' -and $null -ne $_.WorkUnitsPerJoule -and $null -ne $_.WorkUnit
        } | Sort-Object WorkUnitsPerJoule -Descending)
        $workloadName = [string]$group.Group[0].Workload
        if ($comparable.Count -ge 2) {
            $best = $comparable[0]
            $lines.Add(('- **{0}:** highest measured generation efficiency in this dataset was `{1}` at `{2}` tokens/J. Treat it as a candidate for repetition, not a universal best limit.' -f
                (Format-CAMarkdownValue $workloadName),
                (Format-CAMarkdownValue $best.Profile),
                (Format-CAMarkdownValue $best.GenerationTokensPerJoule '0.000000')))
        }
        elseif ($workComparable.Count -ge 2) {
            $best = $workComparable[0]
            $unit = [string]$best.WorkUnit
            $lines.Add(('- **{0}:** highest measured {1} efficiency in this dataset was `{2}` at `{3}` {1}/J. Treat it as a candidate for repetition, not a universal best limit.' -f
                (Format-CAMarkdownValue $workloadName),
                (Format-CAMarkdownValue $unit),
                (Format-CAMarkdownValue $best.Profile),
                (Format-CAMarkdownValue $best.WorkUnitsPerJoule '0.000000000')))
        }
        else {
            $lines.Add("- **$(Format-CAMarkdownValue $workloadName):** fewer than two comparable passed runs; no efficiency leader is reported.")
        }
    }

    $lines.Add('')
    $lines.Add('Generated from schema-v1/v2 anonymized exports. `N/A` is retained as missing evidence rather than converted to zero.')
    return $lines -join "`n"
}

Export-ModuleMember -Function @(
    'Assert-CAPowerCurvePrivacy',
    'Assert-CAPowerCurveRun',
    'ConvertTo-CAPowerCurveRows',
    'New-CAPowerCurveMarkdown'
)
