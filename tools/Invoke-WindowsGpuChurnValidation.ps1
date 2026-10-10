[CmdletBinding()]
param(
    [string]$AppPath,
    [string]$BrowserPath,
    [string]$ResultPath = (Join-Path (Get-Location) 'windows-gpu-pdh-raw-churn.json'),
    [string]$SummaryPath,
    [ValidateRange(20, 600)]
    [int]$DurationSeconds = 60,
    [ValidateRange(1000, 5000)]
    [int]$PollMilliseconds = 1000,
    [ValidateRange(2, 60)]
    [int]$ChurnStartSeconds = 5,
    [ValidateRange(5, 120)]
    [int]$ChurnSeconds = 15
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($AppPath)) {
    $AppPath = Join-Path $PSScriptRoot '..\dist\desktop-win-x64-self-contained\CAAutoConfig.exe'
}
if (($ChurnStartSeconds + $ChurnSeconds + 5) -gt $DurationSeconds) {
    throw 'DurationSeconds must retain at least five seconds after the browser fixture stops.'
}

$resolvedApp = (Resolve-Path -LiteralPath $AppPath).Path
$fixturePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\tests\fixtures\windows-gpu-churn.html')).Path
if ([string]::IsNullOrWhiteSpace($BrowserPath)) {
    $browserCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
    )
    $BrowserPath = $browserCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($BrowserPath)) {
    throw 'No supported Edge or Chrome executable was found.'
}
$resolvedBrowser = (Resolve-Path -LiteralPath $BrowserPath).Path
$resolvedResult = [IO.Path]::GetFullPath($ResultPath)
if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
    $SummaryPath = [IO.Path]::Combine(
        [IO.Path]::GetDirectoryName($resolvedResult),
        [IO.Path]::GetFileNameWithoutExtension($resolvedResult) + '.churn-summary.json')
}
$resolvedSummary = [IO.Path]::GetFullPath($SummaryPath)
if ([string]::Equals($resolvedResult, $resolvedSummary, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ResultPath and SummaryPath must be different files.'
}
$resultDirectory = Split-Path -Parent $resolvedResult
if (-not [string]::IsNullOrWhiteSpace($resultDirectory)) {
    New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
}
$summaryDirectory = Split-Path -Parent $resolvedSummary
if (-not [string]::IsNullOrWhiteSpace($summaryDirectory)) {
    New-Item -ItemType Directory -Path $summaryDirectory -Force | Out-Null
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$profilePath = [IO.Path]::GetFullPath((Join-Path $tempRoot ('ca-gpu-churn-' + [Guid]::NewGuid().ToString('N'))))
if (-not $profilePath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($profilePath) -notlike 'ca-gpu-churn-*') {
    throw 'Refusing an unsafe temporary browser-profile path.'
}
New-Item -ItemType Directory -Path $profilePath | Out-Null

function Get-OwnedBrowserProcesses {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and
        [string]::Equals($_.ExecutablePath, $resolvedBrowser, [StringComparison]::OrdinalIgnoreCase) -and
        $_.CommandLine -and
        $_.CommandLine.IndexOf($profilePath, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
}

function Stop-OwnedBrowserProcesses {
    foreach ($process in @(Get-OwnedBrowserProcesses)) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

$pollProcess = $null
$browserProcess = $null
$startedUtc = [DateTime]::UtcNow
$positiveBrowserCounterSamples = 0
$maximumBrowserCounter = 0.0
$maximumNvidiaLoad = 0
$browserProcessObserved = $false

try {
    $pollArguments = @(
        '--windows-gpu-poll-result', ('"{0}"' -f $resolvedResult),
        '--windows-gpu-poll-seconds', $DurationSeconds,
        '--windows-gpu-poll-ms', $PollMilliseconds,
        '--windows-gpu-provider', 'pdh-raw'
    )
    $pollProcess = Start-Process -FilePath $resolvedApp -ArgumentList $pollArguments -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds $ChurnStartSeconds

    $fixtureUri = ([Uri]$fixturePath).AbsoluteUri
    $browserArguments = @(
        '--headless=new',
        ('--user-data-dir="{0}"' -f $profilePath),
        '--disable-background-networking',
        '--disable-component-update',
        '--disable-default-apps',
        '--disable-sync',
        '--metrics-recording-only',
        '--no-first-run',
        '--no-default-browser-check',
        '--enable-gpu',
        '--enable-gpu-rasterization',
        '--disable-software-rasterizer',
        '--use-angle=d3d11',
        ('"{0}"' -f $fixtureUri)
    )
    $browserProcess = Start-Process -FilePath $resolvedBrowser -ArgumentList $browserArguments -PassThru -WindowStyle Hidden
    $churnDeadline = [DateTime]::UtcNow.AddSeconds($ChurnSeconds)

    while ([DateTime]::UtcNow -lt $churnDeadline) {
        $owned = @(Get-OwnedBrowserProcesses)
        if ($owned.Count -gt 0) {
            $browserProcessObserved = $true
            $pidAlternation = ($owned.ProcessId | ForEach-Object { [regex]::Escape([string]$_) }) -join '|'
            $instancePattern = '^pid_(?:' + $pidAlternation + ')_'
            try {
                $counter = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop
                foreach ($sample in @($counter.CounterSamples | Where-Object { $_.InstanceName -match $instancePattern })) {
                    $value = [double]$sample.CookedValue
                    if ($value -gt $maximumBrowserCounter) { $maximumBrowserCounter = $value }
                    if ($value -gt 0) { $positiveBrowserCounterSamples++ }
                }
            }
            catch {
                # The primary benchmark retains its own failure. This optional
                # corroboration must not alter or fabricate that result.
            }
        }

        try {
            $loads = @(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>$null |
                ForEach-Object { [int]$_.Trim() })
            if ($loads.Count -gt 0) {
                $sampleMaximum = ($loads | Measure-Object -Maximum).Maximum
                if ($sampleMaximum -gt $maximumNvidiaLoad) { $maximumNvidiaLoad = $sampleMaximum }
            }
        }
        catch {
            # NVIDIA corroboration is optional; the WDDM report is vendor-neutral.
        }
        Start-Sleep -Milliseconds 500
    }

    Stop-OwnedBrowserProcesses
    $browserProcess = $null

    $elapsedSeconds = ([DateTime]::UtcNow - $startedUtc).TotalSeconds
    $waitMilliseconds = [Math]::Max(1000, [int](($DurationSeconds - $elapsedSeconds + 10) * 1000))
    if (-not $pollProcess.WaitForExit($waitMilliseconds)) {
        throw 'The bounded telemetry process did not exit in time.'
    }
    if ($pollProcess.ExitCode -ne 0) {
        throw "The bounded telemetry process failed with exit code $($pollProcess.ExitCode)."
    }

    $report = Get-Content -Raw -LiteralPath $resolvedResult | ConvertFrom-Json
    $status = if ($browserProcessObserved -and $positiveBrowserCounterSamples -gt 0) {
        'CHURN_OBSERVED'
    }
    else {
        'CHURN_NOT_PROVEN'
    }
    $reportHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedResult).Hash.ToLowerInvariant()
    $browserVersion = (Get-Item -LiteralPath $resolvedBrowser).VersionInfo.ProductVersion
    $summary = [ordered]@{
        schemaVersion                    = 1
        capturedUtc                      = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        scenario                         = 'deliberate-gpu-process-start-stop-churn'
        status                           = $status
        fixture                          = 'local-webgl-file'
        browserProduct                   = [IO.Path]::GetFileNameWithoutExtension($resolvedBrowser)
        browserVersion                   = $browserVersion
        durationSeconds                  = $DurationSeconds
        intervalMilliseconds             = $PollMilliseconds
        churnStartSeconds                = $ChurnStartSeconds
        churnDurationSeconds             = $ChurnSeconds
        browserProcessObserved           = $browserProcessObserved
        positiveBrowserGpuCounterSamples = $positiveBrowserCounterSamples
        maximumBrowserGpuCounter         = [Math]::Round($maximumBrowserCounter, 3)
        maximumNvidiaLoadPercent         = $maximumNvidiaLoad
        pollingReportSha256              = $reportHash
        counterProvider                  = $report.counterProvider
        completedCollections             = $report.completedCollections
        fullMappings                     = $report.successfulMappingCollections
        partialMappings                  = $report.partialMappingCollections
        unavailableCollections           = $report.unavailableCollections
        engineValidCollections           = $report.successfulEngineLoadCollections
        memoryValidCollections           = $report.successfulDedicatedMemoryCollections
        suppressedOverlaps               = $report.suppressedOverlaps
        failureReasonCounts              = @($report.failureReasonCounts)
        canUseInHud                      = $report.canUseInHud
        hardwareWrites                   = $report.hardwareWrites
        networkAccess                    = $report.networkAccess
        elevationRequested               = $report.elevationRequested
        rawAdapterIdentifiersIncluded    = $report.rawAdapterIdentifiersIncluded
        fixtureHardwareWrites            = $false
        fixtureElevationRequested        = $false
        fixtureUsesLocalFileOnly          = $true
    }
    $summaryJson = $summary | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText(
        $resolvedSummary,
        $summaryJson + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))

    [pscustomobject]@{
        Status                           = $status
        BrowserProcessObserved           = $browserProcessObserved
        PositiveBrowserGpuCounterSamples = $positiveBrowserCounterSamples
        MaximumBrowserGpuCounter         = [Math]::Round($maximumBrowserCounter, 3)
        MaximumNvidiaLoadPercent         = $maximumNvidiaLoad
        CounterProvider                  = $report.counterProvider
        CompletedCollections             = $report.completedCollections
        FullMappings                     = $report.successfulMappingCollections
        PartialMappings                  = $report.partialMappingCollections
        UnavailableCollections           = $report.unavailableCollections
        EngineValidCollections           = $report.successfulEngineLoadCollections
        MemoryValidCollections           = $report.successfulDedicatedMemoryCollections
        SuppressedOverlaps               = $report.suppressedOverlaps
        FailureReasonCounts              = @($report.failureReasonCounts)
        CanUseInHud                      = $report.canUseInHud
        HardwareWrites                   = $report.hardwareWrites
        NetworkAccess                    = $report.networkAccess
        ElevationRequested               = $report.elevationRequested
        RawAdapterIdentifiersIncluded    = $report.rawAdapterIdentifiersIncluded
        ResultPath                       = $resolvedResult
        SummaryPath                      = $resolvedSummary
    }
}
finally {
    if ($pollProcess -and -not $pollProcess.HasExited) {
        Stop-Process -Id $pollProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-OwnedBrowserProcesses
    if (Test-Path -LiteralPath $profilePath) {
        $resolvedProfile = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $profilePath).Path)
        if (-not $resolvedProfile.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedProfile) -notlike 'ca-gpu-churn-*') {
            throw 'Refusing unsafe temporary browser-profile cleanup.'
        }
        Remove-Item -LiteralPath $resolvedProfile -Recurse -Force
    }
}
