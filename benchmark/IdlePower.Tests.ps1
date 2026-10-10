[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'IdlePower.psm1') -Force

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

$baselineText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\idle-dual-3090-baseline.json')
$candidateText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\idle-dual-3090-candidate.json')

function New-IdleRunSet {
    param([ValidateSet('live', 'fixture')][string]$Source = 'live', [int]$Repetitions = 3)

    $list = New-Object Collections.Generic.List[object]
    foreach ($templateText in @($baselineText, $candidateText)) {
        for ($repetition = 1; $repetition -le $Repetitions; $repetition++) {
            $copy = $templateText | ConvertFrom-Json
            $copy.source = $Source
            $copy.runId = "$($copy.runId)-$Source-$repetition"
            $copy.protocol.repetition = $repetition
            $list.Add($copy)
        }
    }
    return $list.ToArray()
}

Test-Case 'idle schema and fixture runs retain explicit privacy and clock policy' {
    $schema = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'idle-schema-v1.json') | ConvertFrom-Json
    Assert-True ([int]$schema.properties.schemaVersion.const -eq 1) 'Idle schema version is wrong.'
    Assert-True (@($schema.required) -contains 'condition') 'Idle schema does not require a condition.'
    foreach ($run in @(New-IdleRunSet -Source fixture -Repetitions 1)) {
        Assert-CAIdlePowerRun -Run $run | Out-Null
        Assert-True (-not [bool]$run.privacy.containsGpuUuid) 'Fixture claims to contain a GPU UUID.'
    }
}

Test-Case 'idle rows sum per-GPU means and retain utilization evidence' {
    $rows = @(ConvertTo-CAIdlePowerRows -Runs (New-IdleRunSet -Source fixture -Repetitions 1))
    Assert-True ([Math]::Abs([double]$rows[0].MeanBoardPowerWatts - 60.0) -lt 0.001) 'Baseline combined board power is wrong.'
    Assert-True ([Math]::Abs([double]$rows[1].MeanBoardPowerWatts - 63.0) -lt 0.001) 'Candidate combined board power is wrong.'
    Assert-True ([double]$rows[0].P95UtilizationPercent -le 2 -and [int]$rows[0].SampleShortfall -eq 0) 'Idle quality evidence is wrong.'
}

Test-Case 'complete live evidence passes the idle regression gate without applying anything' {
    $gate = Test-CAIdlePowerRegression -Runs (New-IdleRunSet -Source live)
    Assert-True ($gate.GateStatus -eq 'PASS') 'Complete low-regression live evidence did not pass.'
    Assert-True ([bool]$gate.CanProceedPastIdleGate) 'Passing live evidence did not clear the idle-only gate.'
    Assert-True ([Math]::Abs([double]$gate.DeltaWatts - 3.0) -lt 0.001 -and [Math]::Abs([double]$gate.DeltaPercent - 5.0) -lt 0.001) 'Combined idle delta is wrong.'
    Assert-True (-not [bool]$gate.HardwareWrites) 'The pure gate reported a hardware write.'
}

Test-Case 'fixture evidence can exercise thresholds but never authorize a recommendation' {
    $gate = Test-CAIdlePowerRegression -Runs (New-IdleRunSet -Source fixture)
    Assert-True ($gate.GateStatus -eq 'FIXTURE' -and [bool]$gate.WouldPassThresholds) 'Fixture threshold evaluation is wrong.'
    Assert-True (-not [bool]$gate.CanProceedPastIdleGate) 'Fixture data advanced past the idle gate.'
    Assert-True (@($gate.ReasonCodes) -contains 'fixture-source') 'Fixture evidence boundary is missing.'
}

Test-Case 'idle power regression blocks the candidate globally and per GPU' {
    $runs = @(New-IdleRunSet -Source live)
    foreach ($run in @($runs | Where-Object condition -eq 'candidate')) {
        foreach ($gpu in @($run.gpus)) {
            foreach ($sample in @($gpu.samples)) { $sample.powerDrawWatts = [double]$sample.powerDrawWatts + 10 }
        }
    }
    $gate = Test-CAIdlePowerRegression -Runs $runs
    Assert-True ($gate.GateStatus -eq 'REGRESSION') 'A large idle power increase was not blocked.'
    Assert-True (-not [bool]$gate.CanProceedPastIdleGate) 'A regressing clock lock advanced past the idle gate.'
    Assert-True (@($gate.ReasonCodes) -contains 'idle-power-regression') 'Regression reason code is missing.'
    Assert-True (@($gate.PerGpu | Where-Object WithinThreshold).Count -eq 0) 'Per-GPU regressions were not exposed.'
}

Test-Case 'insufficient repetitions and failed runs fail closed' {
    $twoRuns = @(New-IdleRunSet -Source live -Repetitions 2)
    $gate = Test-CAIdlePowerRegression -Runs $twoRuns
    Assert-True ($gate.GateStatus -eq 'INSUFFICIENT' -and @($gate.ReasonCodes) -contains 'insufficient-repetitions') 'Two repetitions did not fail closed.'

    $failedRuns = @(New-IdleRunSet -Source live)
    $failedRuns[-1].result.status = 'failed'
    $failedRuns[-1].result.error = 'fixture telemetry interruption'
    $failed = Test-CAIdlePowerRegression -Runs $failedRuns
    Assert-True ($failed.GateStatus -eq 'INSUFFICIENT' -and @($failed.ReasonCodes) -contains 'failed-or-incomplete-run') 'A failed repetition disappeared from the gate.'
}

Test-Case 'missing telemetry and a busy desktop fail closed' {
    $missingRuns = @(New-IdleRunSet -Source live)
    $missingRuns[0].gpus[0].samples[0].powerDrawWatts = $null
    $missing = Test-CAIdlePowerRegression -Runs $missingRuns
    Assert-True ($missing.GateStatus -eq 'INSUFFICIENT' -and @($missing.ReasonCodes) -contains 'missing-or-short-telemetry') 'Missing board power did not fail closed.'

    $busyRuns = @(New-IdleRunSet -Source live)
    foreach ($sample in @($busyRuns[0].gpus[0].samples)) { $sample.utilizationPercent = 30 }
    $busy = Test-CAIdlePowerRegression -Runs $busyRuns
    Assert-True ($busy.GateStatus -eq 'INSUFFICIENT' -and @($busy.ReasonCodes) -contains 'not-idle') 'Busy telemetry was treated as idle.'
}

Test-Case 'hardware, driver, profile, and repetition mixing fail closed' {
    $mixedHardware = @(New-IdleRunSet -Source live)
    $mixedHardware[-1].gpus[0].driver = 'different-driver'
    $hardwareGate = Test-CAIdlePowerRegression -Runs $mixedHardware
    Assert-True (@($hardwareGate.ReasonCodes) -contains 'mixed-hardware-or-driver') 'Mixed driver evidence was ranked together.'

    $mixedProfile = @(New-IdleRunSet -Source live)
    $mixedProfile[-1].profile.label = 'Different candidate'
    $profileGate = Test-CAIdlePowerRegression -Runs $mixedProfile
    Assert-True (@($profileGate.ReasonCodes) -contains 'mixed-profile-within-condition') 'Mixed candidate profiles were ranked together.'

    $duplicate = @(New-IdleRunSet -Source live)
    $duplicate[-1].protocol.repetition = 2
    $duplicateGate = Test-CAIdlePowerRegression -Runs $duplicate
    Assert-True (@($duplicateGate.ReasonCodes) -contains 'duplicate-repetition-number') 'Duplicate repetitions were accepted.'
}

Test-Case 'validation rejects missing clock declaration and privacy leaks' {
    $missingClock = $candidateText | ConvertFrom-Json
    $missingClock.profile.graphicsClockMaximumMHz = $null
    Assert-Throws { Assert-CAIdlePowerRun -Run $missingClock | Out-Null } 'requires graphicsClockMaximumMHz' 'Persistent lock without a clock maximum was accepted.'

    $falseAuto = $baselineText | ConvertFrom-Json
    $falseAuto.profile.graphicsClockMaximumMHz = 1700
    Assert-Throws { Assert-CAIdlePowerRun -Run $falseAuto | Out-Null } 'vendor-auto baseline must not declare' 'Vendor-auto baseline accepted a declared clock lock.'

    $leak = $baselineText | ConvertFrom-Json
    $leak | Add-Member -NotePropertyName machineName -NotePropertyValue 'private-machine'
    Assert-Throws { Assert-CAIdlePowerRun -Run $leak | Out-Null } 'Sensitive field' 'Machine-identifying field was accepted.'
}

Test-Case 'gate report states the fixture and progression boundaries' {
    $fixtureMarkdown = New-CAIdlePowerGateMarkdown -Runs (New-IdleRunSet -Source fixture)
    Assert-True ($fixtureMarkdown -match 'Gate status:\*\* `FIXTURE`') 'Fixture gate status is missing from Markdown.'
    Assert-True ($fixtureMarkdown -match 'synthetic data can never authorize') 'Fixture authorization boundary is missing.'
    Assert-True ($fixtureMarkdown -match 'does not change power, clock, voltage, or fan') 'Read-only boundary is missing.'

    $liveMarkdown = New-CAIdlePowerGateMarkdown -Runs (New-IdleRunSet -Source live)
    Assert-True ($liveMarkdown -match 'separate workload, stability, temperature, and rollback gates') 'Passing report skips remaining gates.'
}

Test-Case 'dry-run report uses fixtures and performs no hardware access' {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('ca-idle-gate-' + [Guid]::NewGuid().ToString('N') + '.md')
    try {
        $result = & (Join-Path $PSScriptRoot 'New-IdlePowerGateReport.ps1') -DryRun -OutputPath $temporary
        $content = Get-Content -Raw -LiteralPath $temporary
        Assert-True ($result.GateStatus -eq 'FIXTURE' -and [int]$result.Runs -eq 6) 'Dry-run result is wrong.'
        Assert-True (-not [bool]$result.HardwareReads -and -not [bool]$result.HardwareWrites) 'Dry-run reported hardware access.'
        Assert-True ($content -notmatch '(?i)GPU-[0-9a-f-]{12,}|[a-z]:\\users\\') 'Dry-run report leaked a protected identifier.'
    }
    finally { Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $temporary }
}

Test-Case 'idle recorder contains no NVIDIA mutation command' {
    $script = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Record-IdlePowerRun.ps1')
    Assert-True ($script -notmatch '(?im)(?:^|\s)-(?:pl|lgc|rgc|rac|ac)\b') 'Idle recorder contains an NVIDIA mutation flag.'
    Assert-True ($script -match 'HardwareWrites\s*=\s*\$false') 'Idle recorder does not explicitly report zero hardware writes.'
    Assert-True ($script -match '--query-gpu=') 'Idle recorder does not contain a query-only NVIDIA telemetry call.'
}

Write-Host "$passed idle-power gate tests passed. No GPU settings were read or changed by the fixture suite." -ForegroundColor Cyan
