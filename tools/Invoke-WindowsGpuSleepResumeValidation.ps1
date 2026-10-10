[CmdletBinding()]
param(
    [string]$AppPath,

    [string]$ResultPath = (Join-Path (Get-Location) 'windows-gpu-pdh-raw-sleep-resume.json'),

    [string]$SummaryPath,

    [ValidateRange(120, 1800)]
    [int]$DurationSeconds = 300,

    [ValidateRange(1000, 5000)]
    [int]$PollMilliseconds = 2000,

    [ValidateRange(1, 600)]
    [int]$MinimumPreSleepSeconds = 10,

    [ValidateRange(1, 600)]
    [int]$MinimumPostWakeSeconds = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (($MinimumPreSleepSeconds + $MinimumPostWakeSeconds + 10) -gt $DurationSeconds) {
    throw 'DurationSeconds must leave both required awake windows plus time for a manual sleep/resume.'
}

if ([string]::IsNullOrWhiteSpace($AppPath)) {
    $AppPath = Join-Path $PSScriptRoot '..\dist\desktop-win-x64-self-contained\CAAutoConfig.exe'
}
$resolvedApp = (Resolve-Path -LiteralPath $AppPath).Path
$resolvedResult = [IO.Path]::GetFullPath($ResultPath)
if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
    $SummaryPath = [IO.Path]::Combine(
        [IO.Path]::GetDirectoryName($resolvedResult),
        [IO.Path]::GetFileNameWithoutExtension($resolvedResult) + '.sleep-resume-summary.json')
}
$resolvedSummary = [IO.Path]::GetFullPath($SummaryPath)
if ([string]::Equals($resolvedResult, $resolvedSummary, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ResultPath and SummaryPath must be different files.'
}
foreach ($path in @($resolvedResult, $resolvedSummary)) {
    if (Test-Path -LiteralPath $path) {
        throw "Refusing to overwrite existing evidence: $path"
    }
    $directory = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

$provider = 'Microsoft-Windows-Power-Troubleshooter'
$eventId = 1
$baselineEvent = Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    ProviderName = $provider
    Id = $eventId
} -MaxEvents 1 -ErrorAction SilentlyContinue
$baselineRecordId = if ($null -eq $baselineEvent) { 0L } else { [long]$baselineEvent.RecordId }
$startedUtc = [DateTime]::UtcNow
$pollProcess = $null

try {
    $arguments = @(
        '--windows-gpu-poll-result', ('"{0}"' -f $resolvedResult),
        '--windows-gpu-poll-seconds', $DurationSeconds,
        '--windows-gpu-poll-ms', $PollMilliseconds,
        '--windows-gpu-provider', 'pdh-raw'
    )
    $pollProcess = Start-Process -FilePath $resolvedApp -ArgumentList $arguments -PassThru -WindowStyle Hidden
    Write-Host "Raw-PDH collection is running. Wait at least $MinimumPreSleepSeconds seconds, put Windows to sleep manually, resume it, then leave at least $MinimumPostWakeSeconds seconds before the run ends." -ForegroundColor Cyan
    Write-Host 'This harness never initiates sleep, changes power settings, elevates, accesses the network, or changes a GPU setting.' -ForegroundColor DarkCyan
    $pollProcess.WaitForExit()
    if ($pollProcess.ExitCode -ne 0) {
        throw "The bounded telemetry process failed with exit code $($pollProcess.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $resolvedResult -PathType Leaf)) {
        throw 'The bounded telemetry process did not create its report.'
    }
    $endedUtc = [DateTime]::UtcNow

    $eventLogReadSucceeded = $true
    $newEvents = @()
    try {
        $newEvents = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = $provider
            Id = $eventId
            StartTime = $startedUtc.AddMinutes(-1)
        } -ErrorAction Stop | Where-Object { [long]$_.RecordId -gt $baselineRecordId })
    }
    catch {
        if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound,*GetWinEventCommand') {
            $newEvents = @()
        }
        else {
            $eventLogReadSucceeded = $false
        }
    }

    $sleepTimeUtc = $null
    $wakeTimeUtc = $null
    if ($newEvents.Count -eq 1) {
        [xml]$eventXml = $newEvents[0].ToXml()
        $eventData = @{}
        foreach ($node in @($eventXml.Event.EventData.Data)) {
            $eventData[[string]$node.Name] = [string]$node.InnerText
        }
        $sleepTimeUtc = $eventData['SleepTime']
        $wakeTimeUtc = $eventData['WakeTime']
    }

    $analyzer = Join-Path $PSScriptRoot 'New-WindowsGpuSleepResumeValidationSummary.ps1'
    & $analyzer `
        -WindowsReportPath $resolvedResult `
        -OutputPath $resolvedSummary `
        -CollectionStartedUtc $startedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture) `
        -CollectionEndedUtc $endedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture) `
        -ResumeEventCount $newEvents.Count `
        -SleepTimeUtc $sleepTimeUtc `
        -WakeTimeUtc $wakeTimeUtc `
        -EventLogReadSucceeded:$eventLogReadSucceeded `
        -MinimumPreSleepSeconds $MinimumPreSleepSeconds `
        -MinimumPostWakeSeconds $MinimumPostWakeSeconds
}
finally {
    if ($pollProcess -and -not $pollProcess.HasExited) {
        Stop-Process -Id $pollProcess.Id -Force -ErrorAction SilentlyContinue
    }
}
