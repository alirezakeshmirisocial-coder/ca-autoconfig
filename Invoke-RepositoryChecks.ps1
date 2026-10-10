[CmdletBinding()]
param(
    [ValidateSet('PowerShell', 'Full')]
    [string]$Suite = 'Full',

    [string]$ResultPath,

    [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$powerShell = Get-Command pwsh -ErrorAction SilentlyContinue
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue

$steps = @(
    [pscustomobject]@{ Name = 'Guard smoke'; Kind = 'PowerShell'; RelativePath = 'tests\Guard.Smoke.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'HUD compile and policy'; Kind = 'PowerShell'; RelativePath = 'tests\SystemOverlay.Smoke.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Compiled desktop smoke'; Kind = 'PowerShell'; RelativePath = 'tests\DesktopApp.Smoke.Tests.ps1'; FullOnly = $true },
    [pscustomobject]@{ Name = 'Desktop package verifier'; Kind = 'PowerShell'; RelativePath = 'tests\DesktopPackageVerifier.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Clean-machine sandbox preparation'; Kind = 'PowerShell'; RelativePath = 'tests\CleanMachineSandbox.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Windows GPU capability probe'; Kind = 'PowerShell'; RelativePath = 'tests\WindowsGpuCapability.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Windows GPU churn harness policy'; Kind = 'PowerShell'; RelativePath = 'tests\WindowsGpuChurnHarness.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Windows GPU loaded-evidence linker'; Kind = 'PowerShell'; RelativePath = 'tests\WindowsGpuLoadedValidation.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Windows GPU sleep-resume validation'; Kind = 'PowerShell'; RelativePath = 'tests\WindowsGpuSleepResumeValidation.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Windows GPU evidence preflight'; Kind = 'PowerShell'; RelativePath = 'tests\WindowsGpuEvidenceBundle.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Display diagnostics preflight'; Kind = 'PowerShell'; RelativePath = 'tests\DisplayDiagnostics.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'HUD overhead evidence policy'; Kind = 'PowerShell'; RelativePath = 'tests\HudOverhead.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Static landing-page policy'; Kind = 'PowerShell'; RelativePath = 'tests\LandingPage.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Release quick-start policy'; Kind = 'PowerShell'; RelativePath = 'tests\QuickStart.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Repository-check orchestration'; Kind = 'PowerShell'; RelativePath = 'tests\RepositoryChecks.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Windows GPU counter mapping'; Kind = 'DotNetProject'; RelativePath = 'src\CAAutoConfig.Telemetry.Tests\CAAutoConfig.Telemetry.Tests.csproj'; FullOnly = $true },
    [pscustomobject]@{ Name = 'Privileged helper safety'; Kind = 'PowerShell'; RelativePath = 'tests\GpuLimits.Safety.Tests.ps1'; FullOnly = $true },
    [pscustomobject]@{ Name = 'Read-only GPU limit plan'; Kind = 'PowerShell'; RelativePath = 'tests\GpuLimitPlan.Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Power-curve calculation and privacy'; Kind = 'PowerShell'; RelativePath = 'benchmark\Run-Tests.ps1'; FullOnly = $false },
    [pscustomobject]@{ Name = 'Adaptive fan policy'; Kind = 'PowerShell'; RelativePath = 'fan-control\Run-Tests.ps1'; FullOnly = $false }
)

$selectedSteps = @($steps | Where-Object { $Suite -eq 'Full' -or -not $_.FullOnly })
foreach ($step in $selectedSteps) {
    $step | Add-Member -NotePropertyName Path -NotePropertyValue (Join-Path $root $step.RelativePath)
    if (-not (Test-Path -LiteralPath $step.Path -PathType Leaf)) {
        throw "Repository check input is missing: $($step.RelativePath)"
    }
}

if ($ListOnly) {
    $selectedSteps | Select-Object Name, Kind, RelativePath, FullOnly
    return
}

if ($null -eq $powerShell) {
    throw 'PowerShell 7 (pwsh) is required to run repository checks.'
}
if ($Suite -eq 'Full' -and $null -eq $dotnet) {
    throw 'The Full suite requires the .NET SDK. No checks were run; use -Suite PowerShell only for an explicitly incomplete local pass.'
}

$startedUtc = [DateTime]::UtcNow
$results = @()
$failed = $false

foreach ($step in $selectedSteps) {
    Write-Host "`n=== $($step.Name) ===" -ForegroundColor Cyan
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $exitCode = -1
    try {
        if ($step.Kind -eq 'PowerShell') {
            & $powerShell.Source -NoLogo -NoProfile -File $step.Path
            $exitCode = $LASTEXITCODE
        }
        elseif ($step.Kind -eq 'DotNetProject') {
            & $dotnet.Source run --project $step.Path -c Release
            $exitCode = $LASTEXITCODE
        }
        else {
            throw "Unknown repository check kind: $($step.Kind)"
        }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        $exitCode = 1
    }
    finally {
        $stopwatch.Stop()
    }

    $status = if ($exitCode -eq 0) { 'PASSED' } else { 'FAILED' }
    if ($status -eq 'FAILED') { $failed = $true }
    $results += [pscustomobject]@{
        Name = $step.Name
        Kind = $step.Kind
        Status = $status
        ExitCode = $exitCode
        DurationMilliseconds = [int64]$stopwatch.ElapsedMilliseconds
    }
    Write-Host ("{0}: {1} ({2} ms)" -f $step.Name, $status, $stopwatch.ElapsedMilliseconds) -ForegroundColor $(if ($status -eq 'PASSED') { 'Green' } else { 'Red' })
}

$finishedUtc = [DateTime]::UtcNow
$completeRepositoryValidation = $Suite -eq 'Full' -and -not $failed
$status = if ($failed) { 'FAILED' } elseif ($completeRepositoryValidation) { 'PASSED_FULL_SUITE' } else { 'PASSED_POWERSHELL_SUITE_ONLY' }
$summary = [ordered]@{
    SchemaVersion = 1
    Status = $status
    Suite = $Suite
    CompleteRepositoryValidation = $completeRepositoryValidation
    StartedUtc = $startedUtc.ToString('o')
    FinishedUtc = $finishedUtc.ToString('o')
    DurationMilliseconds = [int64]($finishedUtc - $startedUtc).TotalMilliseconds
    PassedCount = @($results | Where-Object { $_.Status -eq 'PASSED' }).Count
    FailedCount = @($results | Where-Object { $_.Status -eq 'FAILED' }).Count
    Results = $results
    Safety = [ordered]@{
        HardwareWrites = $false
        GpuSettingsChanged = $false
        SleepInitiated = $false
        ExternalPostsCreated = $false
        ResultContainsMachineOrUserIdentity = $false
    }
}

if (-not [String]::IsNullOrWhiteSpace($ResultPath)) {
    $resolvedResult = [IO.Path]::GetFullPath($ResultPath)
    $scriptPath = [IO.Path]::GetFullPath($PSCommandPath)
    if ([String]::Equals($resolvedResult, $scriptPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ResultPath cannot overwrite the repository-check runner.'
    }
    $parent = Split-Path -Parent $resolvedResult
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw 'ResultPath parent directory does not exist.'
    }
    if (Test-Path -LiteralPath $resolvedResult) {
        throw 'ResultPath already exists; refusing to overwrite prior evidence.'
    }
    $json = $summary | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($resolvedResult, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

[pscustomobject]$summary
if ($failed) {
    throw 'One or more repository checks failed.'
}
