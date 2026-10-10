[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'PowerCurve.psm1') -Force

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

$fixturePaths = @(
    (Join-Path $PSScriptRoot 'fixtures\dual-3090-280w.json'),
    (Join-Path $PSScriptRoot 'fixtures\dual-3090-350w.json')
)
$fixtureTextBefore = @($fixturePaths | ForEach-Object { Get-Content -Raw -LiteralPath $_ })
$runs = @($fixtureTextBefore | ForEach-Object { $_ | ConvertFrom-Json })

function ConvertTo-SchemaV2WorkRun {
    param($Run, [double]$Rate, [string]$Unit = 'image')
    $copy = ($Run | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    $copy.schemaVersion = 2
    $copy.result.throughput.promptTokensPerSecond = $null
    $copy.result.throughput.generationTokensPerSecond = $null
    $copy.result.throughput | Add-Member -NotePropertyName workUnitsPerSecond -NotePropertyValue $Rate
    $copy.result.throughput | Add-Member -NotePropertyName workUnit -NotePropertyValue $Unit
    return $copy
}

Test-Case 'schema-v1 fixtures validate and retain explicit missing values' {
    foreach ($run in $runs) { Assert-CAPowerCurveRun -Run $run | Out-Null }
    Assert-True ($null -eq $runs[0].result.throughput.promptTokensPerSecond) 'Missing prompt throughput was not retained as null.'
    Assert-True ($null -eq $runs[0].gpus[0].samples[2].graphicsClockMHz) 'Missing clock telemetry was not retained as null.'
}

Test-Case 'dual-GPU mean power is the sum of per-GPU means' {
    $rows = @(ConvertTo-CAPowerCurveRows -Runs $runs)
    Assert-True ([Math]::Abs([double]$rows[0].MeanBoardPowerWatts - 490.0) -lt 0.0001) '280 W fixture mean board power is wrong.'
    Assert-True ([Math]::Abs([double]$rows[1].MeanBoardPowerWatts - 610.0) -lt 0.0001) '350 W fixture mean board power is wrong.'
}

Test-Case 'generation efficiency is tokens per second divided by mean watts' {
    $row = @(ConvertTo-CAPowerCurveRows -Runs @($runs[0]))[0]
    Assert-True ([Math]::Abs([double]$row.GenerationTokensPerJoule - (21.2 / 490.0)) -lt 0.000001) 'Generation tokens/J calculation is wrong.'
}

Test-Case 'schema-v2 work-unit throughput produces unit-aware efficiency' {
    $workRun = ConvertTo-SchemaV2WorkRun -Run $runs[0] -Rate 0.25
    Assert-CAPowerCurveRun -Run $workRun | Out-Null
    $row = @(ConvertTo-CAPowerCurveRows -Runs @($workRun))[0]
    Assert-True ([double]$row.WorkUnitsPerSecond -eq 0.25 -and [string]$row.WorkUnit -eq 'image') 'Schema-v2 work rate or unit was lost.'
    Assert-True ([Math]::Abs([double]$row.WorkUnitsPerJoule - (0.25 / 490.0)) -lt 0.000000001) 'Work-unit efficiency is wrong.'
}

Test-Case 'schema-v2 report ranks only matching work units' {
    $first = ConvertTo-SchemaV2WorkRun -Run $runs[0] -Rate 0.25
    $second = ConvertTo-SchemaV2WorkRun -Run $runs[1] -Rate 0.30
    $report = New-CAPowerCurveMarkdown -Runs @($first, $second)
    Assert-True ($report -match 'highest measured image efficiency') 'Work-unit leader is missing.'
    Assert-True ($report -match 'image/J') 'Unit-aware efficiency label is missing.'
    Assert-True ($report -match 'GPU0 280 W \+ GPU1 280 W') 'Expected work-unit efficiency leader is missing.'
    Assert-True ($report -notmatch '\$\(Format-CAMarkdownValue') 'Work-unit observation leaked an unexpanded formatter expression.'
}

Test-Case 'schema-v2 rejects a rate without a safe matching unit' {
    $workRun = ConvertTo-SchemaV2WorkRun -Run $runs[0] -Rate 0.25
    $workRun.result.throughput.workUnit = $null
    Assert-Throws { Assert-CAPowerCurveRun -Run $workRun | Out-Null } 'safe non-empty unit' 'Work throughput without a unit was accepted.'
    $workRun.result.throughput.workUnit = 'image/path'
    Assert-Throws { Assert-CAPowerCurveRun -Run $workRun | Out-Null } 'safe non-empty unit' 'Unsafe work unit was accepted.'
}

Test-Case 'peak temperature and sample counts are deterministic' {
    $row = @(ConvertTo-CAPowerCurveRows -Runs @($runs[0]))[0]
    Assert-True ([double]$row.PeakTemperatureC -eq 70.0) 'Peak temperature is wrong.'
    Assert-True ([int]$row.SampleCount -eq 8) 'Sample count is wrong.'
    Assert-True ([int]$row.MissingPowerSamples -eq 0) 'Missing power count is wrong.'
}

Test-Case 'profile names preserve each GPU cap' {
    $row = @(ConvertTo-CAPowerCurveRows -Runs @($runs[0]))[0]
    Assert-True ($row.Profile -eq 'GPU0 280 W + GPU1 280 W') 'Power profile text is wrong.'
}

Test-Case 'report labels the fixture leader without universal claims' {
    $report = New-CAPowerCurveMarkdown -Runs $runs
    Assert-True ($report -match 'highest measured generation efficiency in this dataset') 'Dataset leader is missing.'
    Assert-True ($report -match 'not a universal recommendation') 'Universal-limit disclaimer is missing.'
    Assert-True ($report -match 'GPU0 280 W \+ GPU1 280 W') 'Expected fixture leader is missing.'
    Assert-True ($report -match 'was `GPU0 280 W \+ GPU1 280 W` at `0\.043265` tokens/J') 'Observation sentence does not render the actual leader and efficiency.'
    Assert-True ($report -notmatch '\$\(Format-CAMarkdownValue') 'Report leaked an unexpanded formatter expression.'
}

Test-Case 'different workload names cannot be ranked as comparable' {
    $first = $fixtureTextBefore[0] | ConvertFrom-Json
    $second = $fixtureTextBefore[1] | ConvertFrom-Json
    $second.workload.name = 'Synthetic dual-3090 llama.cpp fixture with different settings'
    $report = New-CAPowerCurveMarkdown -Runs @($first, $second)
    Assert-True ($report -notmatch 'highest measured generation efficiency') 'Different workload names were incorrectly ranked together.'
    Assert-True (@([regex]::Matches($report, 'fewer than two comparable passed runs')).Count -eq 2) 'Different workloads did not receive separate evidence warnings.'
}

Test-Case 'a GPU UUID field is rejected' {
    $copy = ($fixtureTextBefore[0] | ConvertFrom-Json)
    $copy.gpus[0] | Add-Member -NotePropertyName uuid -NotePropertyValue 'GPU-secret'
    Assert-Throws { Assert-CAPowerCurveRun -Run $copy | Out-Null } 'Sensitive field' 'GPU UUID was accepted.'
}

Test-Case 'a user profile path is rejected' {
    $copy = ($fixtureTextBefore[0] | ConvertFrom-Json)
    $copy.workload.name = 'C:\Users\Alice\private-model.gguf'
    Assert-Throws { Assert-CAPowerCurveRun -Run $copy | Out-Null } 'Potential machine or user path' 'User path was accepted.'
}

Test-Case 'a future schema is rejected' {
    $copy = ($fixtureTextBefore[0] | ConvertFrom-Json)
    $copy.schemaVersion = 3
    Assert-Throws { Assert-CAPowerCurveRun -Run $copy | Out-Null } 'Unsupported benchmark schema' 'Future schema was accepted.'
}

Test-Case 'a passed run without throughput is rejected' {
    $copy = ($fixtureTextBefore[0] | ConvertFrom-Json)
    $copy.result.throughput.promptTokensPerSecond = $null
    $copy.result.throughput.generationTokensPerSecond = $null
    Assert-Throws { Assert-CAPowerCurveRun -Run $copy | Out-Null } 'token or work-unit' 'Evidence-free passed run was accepted.'
}

Test-Case 'published schema documents are valid JSON with distinct versions' {
    $schema1 = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'schema-v1.json') | ConvertFrom-Json
    $schema2 = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'schema-v2.json') | ConvertFrom-Json
    Assert-True ([int]$schema1.properties.schemaVersion.const -eq 1) 'schema-v1 identity changed.'
    Assert-True ([int]$schema2.properties.schemaVersion.const -eq 2) 'schema-v2 identity is wrong.'
    Assert-True (@($schema2.properties.result.properties.throughput.required) -contains 'workUnitsPerSecond') 'schema-v2 omits generalized throughput.'
}

Test-Case 'non-finite sample telemetry is rejected' {
    $copy = ($fixtureTextBefore[0] | ConvertFrom-Json)
    $copy.gpus[0].samples[0].powerDrawWatts = [double]::NaN
    Assert-Throws { Assert-CAPowerCurveRun -Run $copy | Out-Null } 'must be null or finite' 'NaN telemetry was accepted.'
}

Test-Case 'dry-run produces a human-readable fixture report' {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('ca-power-report-' + [Guid]::NewGuid().ToString('N') + '.md')
    try {
        $result = & (Join-Path $PSScriptRoot 'New-PowerCurveReport.ps1') -DryRun -OutputPath $temporary
        Assert-True ($result.Status -eq 'Reported' -and [int]$result.Runs -eq 2) 'Dry-run result is wrong.'
        Assert-True (Test-Path -LiteralPath $temporary -PathType Leaf) 'Dry-run report file is missing.'
        Assert-True ((Get-Content -Raw -LiteralPath $temporary) -match 'CA AutoConfig power-curve report') 'Dry-run report content is missing.'
        Assert-True (-not [bool]$result.HardwareWrites) 'Dry-run reported a hardware write.'
    }
    finally { Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $temporary }
}

Test-Case 'recorder source contains query-only NVIDIA operations' {
    $source = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Record-WorkloadRun.ps1')
    Assert-True ($source -match '--query-gpu=') 'Recorder has no NVIDIA query.'
    Assert-True ($source -notmatch '(?i)[''"]-(pl|lgc|rgc|ac)[''"]') 'Recorder contains a mutating NVIDIA flag.'
    Assert-True ($source -notmatch 'Start-ScheduledTask|Register-ScheduledTask|Verb\s+RunAs') 'Recorder contains an elevation or task path.'
}

Test-Case 'analysis leaves fixture bytes unchanged' {
    $fixtureTextAfter = @($fixturePaths | ForEach-Object { Get-Content -Raw -LiteralPath $_ })
    Assert-True ($fixtureTextBefore.Count -eq $fixtureTextAfter.Count) 'Fixture count changed.'
    for ($index = 0; $index -lt $fixtureTextBefore.Count; $index++) {
        Assert-True ($fixtureTextBefore[$index] -ceq $fixtureTextAfter[$index]) "Fixture $index changed during analysis."
    }
}

Test-Case 'share card is deterministic and labels fixtures as non-evidence' {
    $first = New-CAPowerCurveCardSvg -Runs $runs
    $second = New-CAPowerCurveCardSvg -Runs $runs
    Assert-True ($first -ceq $second) 'Power-curve SVG is not deterministic.'
    Assert-True ($first -match 'FIXTURE / NOT HARDWARE EVIDENCE') 'Fixture card is missing its evidence warning.'
    Assert-True ($first -match 'GPU0 280 W \+ GPU1 280 W') 'Expected efficiency candidate is missing from the card.'
    Assert-True ($first -match 'Synthetic fixture leader, not a hardware result') 'Fixture-safe candidate boundary is missing from the card.'
    Assert-True ($first -match 'exact anonymized raw JSON \+ method') 'Raw evidence and method requirement is missing from the card.'
    Assert-True ($first -notmatch 'most efficient measured candidate|Measured leader') 'Fixture card uses measured-hardware language.'
}

Test-Case 'share card rejects unlike workloads and mixed sources' {
    $unlike = $fixtureTextBefore[1] | ConvertFrom-Json
    $unlike.workload.name = 'different workload'
    Assert-Throws { New-CAPowerCurveCardSvg -Runs @($runs[0], $unlike) | Out-Null } 'one exact workload' 'Unlike workloads were accepted by the card.'
    $live = $fixtureTextBefore[1] | ConvertFrom-Json
    $live.source = 'live'
    Assert-Throws { New-CAPowerCurveCardSvg -Runs @($runs[0], $live) | Out-Null } 'mix live and fixture' 'Mixed evidence sources were accepted by the card.'
}

Test-Case 'share card requires two comparable profiles' {
    Assert-Throws { New-CAPowerCurveCardSvg -Runs @($runs[0], $runs[0]) | Out-Null } 'two comparable power profiles' 'A repeated single profile was presented as a curve.'
}

Test-Case 'share card supports schema-v2 work units' {
    $first = ConvertTo-SchemaV2WorkRun -Run $runs[0] -Rate 0.25
    $second = ConvertTo-SchemaV2WorkRun -Run $runs[1] -Rate 0.30
    $card = New-CAPowerCurveCardSvg -Runs @($first, $second)
    Assert-True ($card -match 'image/s') 'Work-unit rate is missing from the card.'
    Assert-True ($card -match 'image/J') 'Work-unit efficiency is missing from the card.'
}

Test-Case 'share card gates live evidence on repetitions and retains failures' {
    $singleLiveA = $fixtureTextBefore[0] | ConvertFrom-Json
    $singleLiveB = $fixtureTextBefore[1] | ConvertFrom-Json
    $singleLiveA.source = 'live'
    $singleLiveB.source = 'live'
    $draft = New-CAPowerCurveCardSvg -Runs @($singleLiveA, $singleLiveB)
    Assert-True ($draft -match 'DRAFT / INSUFFICIENT REPETITIONS') 'Under-repeated live data was presented as measured evidence.'

    $liveRuns = New-Object Collections.Generic.List[object]
    foreach ($templateText in $fixtureTextBefore) {
        for ($repetition = 1; $repetition -le 3; $repetition++) {
            $copy = $templateText | ConvertFrom-Json
            $copy.source = 'live'
            $copy.runId = $copy.runId + "-live-$repetition"
            $copy.protocol.repetition = $repetition
            $liveRuns.Add($copy)
        }
    }
    $measured = New-CAPowerCurveCardSvg -Runs $liveRuns.ToArray()
    Assert-True ($measured -match 'MEASURED / LOCAL HARDWARE') 'Three live repetitions per profile did not clear the evidence gate.'

    $failed = $fixtureTextBefore[0] | ConvertFrom-Json
    $failed.source = 'live'
    $failed.runId = 'failed-retained-run'
    $failed.protocol.repetition = 4
    $failed.result.status = 'failed'
    $failed.result.throughput.promptTokensPerSecond = $null
    $failed.result.throughput.generationTokensPerSecond = $null
    $failed.result.error = 'fixture failure'
    $withFailure = New-CAPowerCurveCardSvg -Runs @($singleLiveA, $singleLiveB, $failed)
    Assert-True ($withFailure -match '1 failed or incomplete') 'Failed-run count is missing from the card.'
    Assert-True ($withFailure -match '1/2 passed') 'Failed repetition disappeared from its profile evidence count.'
}

Test-Case 'dry-run writes a privacy-safe share card without hardware access' {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('ca-power-card-' + [Guid]::NewGuid().ToString('N') + '.svg')
    try {
        $result = & (Join-Path $PSScriptRoot 'New-PowerCurveCard.ps1') -DryRun -OutputPath $temporary
        $content = Get-Content -Raw -LiteralPath $temporary
        Assert-True ($result.Status -eq 'CardCreated' -and [int]$result.Runs -eq 2) 'Dry-run card result is wrong.'
        Assert-True ($content -match '<svg' -and $content -match 'Synthetic data exercises the pipeline only') 'Dry-run SVG content is incomplete.'
        Assert-True ($content -notmatch '(?i)GPU-[0-9a-f-]{12,}|[a-z]:\\users\\') 'Dry-run card leaked a protected identifier.'
        Assert-True (-not [bool]$result.HardwareWrites) 'Dry-run card reported a hardware write.'
    }
    finally { Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $temporary }
}

Write-Host "$passed benchmark tests passed. No GPU settings were read or changed by the fixture suite." -ForegroundColor Cyan
