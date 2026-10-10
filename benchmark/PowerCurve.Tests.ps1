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
    $copy.schemaVersion = 2
    Assert-Throws { Assert-CAPowerCurveRun -Run $copy | Out-Null } 'Unsupported benchmark schema' 'Future schema was accepted.'
}

Test-Case 'a passed run without throughput is rejected' {
    $copy = ($fixtureTextBefore[0] | ConvertFrom-Json)
    $copy.result.throughput.promptTokensPerSecond = $null
    $copy.result.throughput.generationTokensPerSecond = $null
    Assert-Throws { Assert-CAPowerCurveRun -Run $copy | Out-Null } 'must include prompt or generation' 'Evidence-free passed run was accepted.'
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

Write-Host "$passed benchmark tests passed. No GPU settings were read or changed by the fixture suite." -ForegroundColor Cyan
