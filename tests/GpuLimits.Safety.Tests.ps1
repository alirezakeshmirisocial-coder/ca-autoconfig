[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$helperPath = Join-Path $root 'src\CAAutoConfig.GpuHelper\Program.cs'
$helperProjectPath = Join-Path $root 'src\CAAutoConfig.GpuHelper\CAAutoConfig.GpuHelper.csproj'
$helperTestsProjectPath = Join-Path $root 'src\CAAutoConfig.GpuHelper.Tests\CAAutoConfig.GpuHelper.Tests.csproj'
$buildPath = Join-Path $root 'Build-GpuHelper.ps1'
$installPath = Join-Path $root 'Install-GpuLimits.ps1'
$combinedPath = Join-Path $root 'Install-CombinedAutoconfig.ps1'
$controlPanelPath = Join-Path $root 'CA-ControlPanel.ps1'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

foreach ($path in @($buildPath, $installPath, $combinedPath, $controlPanelPath)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $parseMessage = ($errors | ForEach-Object { $_.Message }) -join '; '
    Assert-True ($errors.Count -eq 0) "PowerShell parser errors in $path`: $parseMessage"
}

foreach ($path in @($helperPath, $helperProjectPath, $helperTestsProjectPath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Required compiled-helper source is missing: $path"
}

$helper = Get-Content -Raw -LiteralPath $helperPath
$project = Get-Content -Raw -LiteralPath $helperProjectPath
$install = Get-Content -Raw -LiteralPath $installPath
$combined = Get-Content -Raw -LiteralPath $combinedPath
$controlPanel = Get-Content -Raw -LiteralPath $controlPanelPath

Assert-True ($project -match '<OutputType>Exe</OutputType>' -and $project -match '<PublishSingleFile>true</PublishSingleFile>') 'The privileged helper must be a compiled single-file executable.'
Assert-True ($helper -match 'EnsureElevated\(\)' -and $helper -match 'WindowsBuiltInRole\.Administrator' -and $helper -match 'identity\.IsSystem') 'The helper must reject standard-user direct execution.'
Assert-True ($helper -match 'ArgumentList\.Add\(argument\)' -and $helper -notmatch 'cmd\.exe') 'nvidia-smi arguments must bypass shell command parsing.'
Assert-True ($helper -match 'args\.Length != 7' -and $helper -match 'args\.Length == 1' -and $helper -match 'canonical NVIDIA GPU UUID') 'The helper must expose only strict apply/reset grammars with canonical UUID targets.'
Assert-True ($helper -match 'powerLimitWatts > row\.DefaultPowerWatts \+ 0\.5') 'The helper must refuse a limit above the vendor default.'

$preflightPosition = $helper.IndexOf('inventory = targets.Select(Preflight).ToList()')
$mutationPosition = $helper.IndexOf('RunChecked("set power"')
Assert-True ($preflightPosition -ge 0 -and $mutationPosition -gt $preflightPosition) 'All targets must pass preflight before the first mutation.'
Assert-True ($helper -match 'gpu-limits-backup\.json' -and $helper -match 'OriginalPowerLimitWatts' -and $helper -match 'DeleteRollback') 'The helper must keep and consume a protected exact-value rollback record.'
Assert-True ($helper -match 'RollBackFailedApply' -and $helper -match 'rollback graphics clock' -and $helper -match 'rollback power') 'Apply failures must attempt reverse rollback.'
Assert-True ($helper -match 'restore applied power after failed reset' -and $helper -match 'restore applied clock after failed reset') 'Reset failures must attempt to restore the previously applied profile.'

Assert-True ($install -match 'if \(-not \$AcceptHardwareRisk\)') 'GPU installation must require explicit hardware-risk acknowledgement.'
Assert-True ($install -match 'ExpectedHelperSha256' -and $install -match 'changed between validation and elevation') 'The helper binary must be hash-pinned across UAC.'
Assert-True ($install -match 'internal elevation handoff fields') 'Unprivileged callers must not inject installer-resolved identity or hash handoff fields.'
Assert-True ($install -match 'FileAttributes\]::ReparsePoint' -and $install -match 'SetAccessRuleProtection\(\$true, \$false\)') 'The privileged install path and source must reject reparse points and use a protected ACL.'
Assert-True ($install -match '\$resetTaskName = ''CA GPU Limits Reset''' -and $install -match '-Arguments ''reset''' -and $install -match 'apply --targets') 'Installer must create separate fixed apply and reset tasks.'
Assert-True ($install -match '<Command>\$escapedHelper</Command>' -and $install -notmatch '<Command>\$escapedPowerShell</Command>') 'SYSTEM tasks must execute the compiled helper directly.'
Assert-True ($install -match 'SetSecurityDescriptor\(\$SecurityDescriptor, 0\)' -and $install -match 'GRGX') 'Configured user must have read/run but not task-write access.'
Assert-True ($install -match 'legacy applied profile has no protected original-value record') 'Legacy migration must refuse to invent rollback values.'

Assert-True ($combined -match 'if \(\$InstallPresenceMonitor\)') 'Presence monitoring must remain opt-in.'
Assert-True ($combined -match 'if \(\$InstallGpuLimits -or \$ReinstallGpuTask\)') 'GPU mutation must remain opt-in.'
Assert-True ($controlPanel -match 'Invoke-FixedGpuTask -TaskName \$gpuTaskName' -and $controlPanel -match 'Invoke-FixedGpuTask -TaskName \$gpuResetTaskName') 'Control panel must start only the reviewed fixed tasks.'
Assert-True ($controlPanel -notmatch "'-rgc'" -and $controlPanel -notmatch "'-pl'") 'The standard-user control panel must contain no direct GPU mutation command.'
Assert-True ($controlPanel -notmatch '-Verb RunAs' -and $controlPanel -notmatch '\[switch\]\$Elevated') 'The installed standard-user control panel must never elevate its own writable script.'
Assert-True ($controlPanel -match 'Confirm-UiGpuAction' -and $controlPanel -match 'Assert-HardwareConfirmation') 'Interactive and command-line GPU changes must require explicit confirmation.'
Assert-True ($controlPanel -match '\$expectedByUuid' -and $controlPanel -match 'limits-active=\$profileStatus') 'Status must compare live telemetry with the applied UUID-pinned profile.'

$blockedWithoutRisk = $false
try {
    & $installPath -GpuIndexList '0' -MaxGraphicsClockMHz 1700 -PowerLimitWatts 280 2>$null
}
catch { $blockedWithoutRisk = $_.Exception.Message -match 'opt-in' }
Assert-True $blockedWithoutRisk 'The installer must fail before helper discovery, elevation, or hardware access when acknowledgement is absent.'

$blockedInternalHandoff = $false
try {
    & $installPath -GpuIndexList '0' -MaxGraphicsClockMHz 1700 -PowerLimitWatts 280 -AcceptHardwareRisk `
        -ResolvedGpuUuidList 'GPU-00000000-0000-0000-0000-000000000000' 2>$null
}
catch { $blockedInternalHandoff = $_.Exception.Message -match 'internal elevation handoff' }
Assert-True $blockedInternalHandoff 'A normal caller must not inject installer-resolved UUIDs.'

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnetPath = if ($null -ne $dotnet) { $dotnet.Source } else { Join-Path $root '.tools\dotnet\dotnet.exe' }
Assert-True (Test-Path -LiteralPath $dotnetPath -PathType Leaf) 'The .NET 8 SDK is required to run isolated GPU helper tests.'
& $dotnetPath run --project $helperTestsProjectPath --configuration Release
Assert-True ($LASTEXITCODE -eq 0) 'Compiled GPU helper safety tests failed.'

[pscustomobject]@{
    Status                    = 'Passed'
    CompiledHelper            = $true
    StrictCommandGrammar      = $true
    PreflightBeforeWrite      = $true
    ProtectedExactRollback    = $true
    StableUuidTargets         = $true
    HashPinnedElevation       = $true
    FixedApplyResetTasks      = $true
    ExplicitConfirmation      = $true
    CombinedDefaultsSafe      = $true
}
