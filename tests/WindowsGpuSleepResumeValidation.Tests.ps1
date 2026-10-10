$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$analyzer = Join-Path $root 'tools\New-WindowsGpuSleepResumeValidationSummary.ps1'
$harnessPath = Join-Path $root 'tools\Invoke-WindowsGpuSleepResumeValidation.ps1'
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ca-sleep-resume-tests-' + [Guid]::NewGuid().ToString('N'))))
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($temporaryRoot) -notlike 'ca-sleep-resume-tests-*') {
    throw 'Unsafe temporary test path.'
}
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Json {
    param($Value, [string]$Path)
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Case {
    param(
        $Report,
        [string]$Name,
        [int]$ResumeEventCount,
        [string]$SleepTimeUtc,
        [string]$WakeTimeUtc,
        [bool]$EventLogReadSucceeded = $true
    )
    $reportPath = Join-Path $temporaryRoot ($Name + '-report.json')
    $outputPath = Join-Path $temporaryRoot ($Name + '-summary.json')
    Write-Json $Report $reportPath
    $result = & $analyzer `
        -WindowsReportPath $reportPath `
        -OutputPath $outputPath `
        -CollectionStartedUtc '2026-10-10T12:00:00Z' `
        -CollectionEndedUtc '2026-10-10T12:01:00Z' `
        -ResumeEventCount $ResumeEventCount `
        -SleepTimeUtc $SleepTimeUtc `
        -WakeTimeUtc $WakeTimeUtc `
        -EventLogReadSucceeded:$EventLogReadSucceeded `
        -MinimumPreSleepSeconds 10 `
        -MinimumPostWakeSeconds 10
    [pscustomobject]@{
        Result = $result
        Summary = Get-Content -Raw -LiteralPath $outputPath | ConvertFrom-Json
        Raw = Get-Content -Raw -LiteralPath $outputPath
        ReportPath = $reportPath
        OutputPath = $outputPath
    }
}

try {
    $baseReport = [pscustomobject][ordered]@{
        schemaVersion = 3
        capturedUtc = '2026-10-10T12:00:59.750Z'
        source = 'live-windows-polling-read-only'
        counterProvider = 'windows-pdh-raw-engine'
        elapsedMilliseconds = 60000
        completedCollections = 20
        successfulMappingCollections = 20
        partialMappingCollections = 0
        unavailableCollections = 0
        suppressedOverlaps = 0
        successfulEngineLoadCollections = 20
        successfulDedicatedMemoryCollections = 20
        canUseInHud = $false
        hardwareWrites = $false
        networkAccess = $false
        elevationRequested = $false
        rawAdapterIdentifiersIncluded = $false
        failureReasonCounts = @()
    }

    $ready = Invoke-Case $baseReport 'ready' 1 '2026-10-10T12:00:20Z' '2026-10-10T12:00:30Z'
    Assert-True ($ready.Result.Status -eq 'READY_FOR_MANUAL_SLEEP_RESUME_REVIEW' -and
        [double]$ready.Summary.powerEvent.preSleepSeconds -eq 20 -and
        [double]$ready.Summary.powerEvent.postWakeSeconds -eq 30 -and
        $ready.Raw -match '"reportCapturedUtc"\s*:\s*"2026-10-10T12:00:59\.7500000Z"' -and
        -not [bool]$ready.Summary.canUseInHud -and
        -not [bool]$ready.Summary.promotionAuthorized) 'A valid fixture did not stop at manual review.'
    Write-Output 'PASS valid evidence advances only to manual sleep/resume review'

    $noEvent = Invoke-Case $baseReport 'no-event' 0 $null $null
    $eventSourceFailure = Invoke-Case $baseReport 'event-source-failure' 0 $null $null $false
    Assert-True ($noEvent.Result.Status -eq 'NO_RESUME_OBSERVED' -and
        $eventSourceFailure.Result.Status -eq 'EVENT_SOURCE_UNAVAILABLE') 'No-event evidence and a real event-source failure were conflated.'
    Write-Output 'PASS no-event evidence is distinct from an event-source failure'

    $multiple = Invoke-Case $baseReport 'multiple' 2 $null $null
    Assert-True ($multiple.Result.Status -eq 'MULTIPLE_RESUMES_OBSERVED') 'Multiple resume events were treated as one controlled lifecycle.'
    Write-Output 'PASS multiple resume events require a new controlled run'

    $outside = Invoke-Case $baseReport 'outside' 1 '2026-10-10T11:59:00Z' '2026-10-10T11:59:30Z'
    Assert-True ($outside.Result.Status -eq 'INVALID_RESUME_EVENT' -and
        $null -eq $outside.Summary.powerEvent.sleepTimeUtc -and
        $null -eq $outside.Summary.powerEvent.wakeTimeUtc) 'An out-of-window resume event was accepted or exported.'
    Write-Output 'PASS an out-of-window event cannot prove lifecycle coverage'

    $shortWindow = Invoke-Case $baseReport 'short-window' 1 '2026-10-10T12:00:05Z' '2026-10-10T12:00:55Z'
    Assert-True ($shortWindow.Result.Status -eq 'INSUFFICIENT_PRE_OR_POST_WINDOW') 'Insufficient awake observation passed.'
    Write-Output 'PASS both pre-sleep and post-wake observation windows are required'

    $partialReport = $baseReport | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $partialReport.successfulMappingCollections = 19
    $partialReport.partialMappingCollections = 1
    $partialReport.successfulEngineLoadCollections = 19
    $partialReport.failureReasonCounts = @([pscustomobject]@{ code = 'pdh-engine-baseline-missing-adapter-0'; count = 1 })
    $partial = Invoke-Case $partialReport 'partial' 1 '2026-10-10T12:00:20Z' '2026-10-10T12:00:30Z'
    Assert-True ($partial.Result.Status -eq 'WINDOWS_PROVIDER_PARTIAL') 'A retained post-lifecycle partial was hidden.'
    Write-Output 'PASS provider partials remain blocking evidence'

    $unavailableReport = $baseReport | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $unavailableReport.successfulMappingCollections = 19
    $unavailableReport.unavailableCollections = 1
    $unavailableReport.successfulEngineLoadCollections = 19
    $unavailableReport.successfulDedicatedMemoryCollections = 19
    $unavailable = Invoke-Case $unavailableReport 'unavailable' 1 '2026-10-10T12:00:20Z' '2026-10-10T12:00:30Z'
    Assert-True ($unavailable.Result.Status -eq 'WINDOWS_PROVIDER_UNAVAILABLE') 'An unavailable collection passed.'
    Write-Output 'PASS unavailable or overlapped collections remain blocking evidence'

    Assert-True ($ready.Raw -notmatch 'ready-report\.json|DESKTOP-|S-1-5-|<Event' -and
        -not [bool]$ready.Summary.privacy.computerNameIncluded -and
        -not [bool]$ready.Summary.privacy.rawEventXmlIncluded) 'The summary exposed a filename or raw event identity.'
    $unsafeReport = $baseReport | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $unsafeReport.successfulMappingCollections = 19
    $unsafeReport.partialMappingCollections = 1
    $unsafeReport.successfulEngineLoadCollections = 19
    $unsafeReport.failureReasonCounts = @([pscustomobject]@{ code = 'C:\Users\Private\counter'; count = 1 })
    $unsafePath = Join-Path $temporaryRoot 'unsafe-report.json'
    $unsafeOutput = Join-Path $temporaryRoot 'unsafe-summary.json'
    Write-Json $unsafeReport $unsafePath
    $threw = $false
    try {
        & $analyzer -WindowsReportPath $unsafePath -OutputPath $unsafeOutput `
            -CollectionStartedUtc '2026-10-10T12:00:00Z' -CollectionEndedUtc '2026-10-10T12:01:00Z' -ResumeEventCount 1 `
            -SleepTimeUtc '2026-10-10T12:00:20Z' -WakeTimeUtc '2026-10-10T12:00:30Z' | Out-Null
    }
    catch { $threw = $true }
    Assert-True ($threw -and -not (Test-Path -LiteralPath $unsafeOutput)) 'An unsafe failure reason was accepted or copied.'
    Write-Output 'PASS summaries omit event identity and reject unsafe reason text'

    $collisionHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ready.ReportPath).Hash
    $threw = $false
    try {
        & $analyzer -WindowsReportPath $ready.ReportPath -OutputPath $ready.ReportPath `
            -CollectionStartedUtc '2026-10-10T12:00:00Z' -CollectionEndedUtc '2026-10-10T12:01:00Z' `
            -ResumeEventCount 0 -Force | Out-Null
    }
    catch { $threw = $true }
    Assert-True ($threw -and $collisionHash -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $ready.ReportPath).Hash) 'Output collision changed the input report.'
    Write-Output 'PASS output cannot overwrite its evidence input'

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($harnessPath, [ref]$tokens, [ref]$errors)
    $harness = Get-Content -Raw -LiteralPath $harnessPath
    Assert-True ($errors.Count -eq 0) 'The live sleep/resume harness has PowerShell parse errors.'
    Assert-True ($harness -match "--windows-gpu-provider', 'pdh-raw'" -and
        $harness -match 'ProviderName = \$provider' -and
        $harness -match 'Id = \$eventId') 'The harness is not pinned to raw PDH and the documented resume event.'
    Assert-True ($harness -notmatch '(?i)SetSuspendState|rundll32|psshutdown|shutdown\.exe|Invoke-WebRequest|Invoke-RestMethod|nvidia-smi') 'The harness can force sleep, access the network, or invoke NVIDIA tooling.'
    Assert-True ($harness -match "NoMatchingEventsFound,\*GetWinEventCommand" -and
        $harness -match '\$newEvents\s*=\s*@\(\)') 'An empty event query is not distinguished from an event-log read failure.'
    $startCommands = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Process'
    }, $true))
    Assert-True ($startCommands.Count -eq 1 -and $startCommands[0].Extent.Text -match '-WindowStyle Hidden') 'The bounded collector is not the only hidden child process.'
    Write-Output 'PASS live harness is manual-sleep-only, local, standard-user, and raw-provider pinned'

    Write-Output '10 Windows GPU sleep/resume validation tests passed. Fixtures performed no event-log, network, hardware, or sleep action.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $temporaryRoot).Path)
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notlike 'ca-sleep-resume-tests-*') {
            throw 'Refusing unsafe temporary test cleanup.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
