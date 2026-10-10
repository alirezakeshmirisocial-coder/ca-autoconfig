[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$applyPath = Join-Path $root 'Apply-GpuLimits.ps1'
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

foreach ($path in @($applyPath, $installPath, $combinedPath, $controlPanelPath)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $parseMessage = ($errors | ForEach-Object { $_.Message }) -join '; '
    Assert-True ($errors.Count -eq 0) "PowerShell parser errors in $path`: $parseMessage"
}

$apply = Get-Content -Raw -LiteralPath $applyPath
$install = Get-Content -Raw -LiteralPath $installPath
$combined = Get-Content -Raw -LiteralPath $combinedPath
$controlPanel = Get-Content -Raw -LiteralPath $controlPanelPath

Assert-True ($apply -match '\[Parameter\(Mandatory = \$true\)\]\s*\[ValidateNotNullOrEmpty\(\)\]\s*\[string\]\$GpuIndexList') 'Apply script must require an explicit GPU index list.'
Assert-True ($apply -match '\[Parameter\(Mandatory = \$true\)\]\s*\[ValidateRange\(300, 3000\)\]\s*\[int\]\$MaxGraphicsClockMHz') 'Apply script must require an explicit clock limit.'
Assert-True ($apply -match '\[Parameter\(Mandatory = \$true\)\]\s*\[ValidateRange\(50, 1000\)\]\s*\[int\]\$PowerLimitWatts') 'Apply script must require an explicit power limit.'

$preflightPosition = $apply.IndexOf('$inventoryRows +=')
$mutationPosition = $apply.IndexOf("'-pl', [string]`$PowerLimitWatts")
Assert-True ($preflightPosition -ge 0 -and $mutationPosition -gt $preflightPosition) 'All targets must be inventoried before the first power mutation.'
Assert-True ($apply -match "'-rgc'" -and $apply -match 'OriginalPower' -and $apply -match "rollback\s+=") 'Failure handling must retain best-effort clock and power rollback.'

Assert-True ($install -match 'if \(-not \$AcceptHardwareRisk\)') 'GPU installation must require explicit hardware-risk acknowledgement.'
Assert-True ($install.Contains("'-GpuIndexList', `$gpuIndexArgument")) 'The elevated installer must preserve the explicit GPU list.'
Assert-True ($install -match 'SetAccessRuleProtection\(\$true, \$false\)' -and $install -match 'S-1-5-32-545' -and $install -match 'ReadAndExecute') 'The SYSTEM task script directory must be protected from user writes.'
Assert-True ($install -match 'FileAttributes\]::ReparsePoint') 'The privileged installer must reject a reparse-point install directory.'
Assert-True ($install -match '<SecurityDescriptor>\$escapedTaskSecurityDescriptor</SecurityDescriptor>' -and $install -match 'GRGX') 'The configured user must receive read/run task access without task-write access.'
Assert-True ($install -match 'SetSecurityDescriptor\(\$taskSecurityDescriptor, 0\)' -and $install -match 'GetSecurityDescriptor\(4\)') 'The installer must apply and read back the task security descriptor through the supported API.'
Assert-True ($install.Contains("'-TargetUserName', ('`"{0}`"' -f `$TargetUserName)")) 'Elevation must preserve the requesting Windows user name.'
Assert-True ($install.Contains("'-TargetUserSid', `$TargetUserSid")) 'Elevation must preserve the requesting Windows user SID.'
Assert-True ($combined -match 'if \(\$InstallPresenceMonitor\)') 'Presence monitoring must be opt-in in the combined installer.'
Assert-True ($combined -match 'if \(\$InstallGpuLimits -or \$ReinstallGpuTask\)') 'GPU mutation must be opt-in in the combined installer.'
Assert-True ($controlPanel -match 'function Apply-GpuLimits[\s\S]+?Start-ScheduledTask -TaskName \$gpuTaskName') 'The control panel must trigger the reviewed GPU task instead of rebuilding its command.'
Assert-True ($controlPanel -notmatch '& \$powerShellPath -NoProfile -ExecutionPolicy Bypass -File \$gpuApplyScript') 'The control panel must not invoke the parameterized privileged helper without its approved task arguments.'
Assert-True ($controlPanel -match "'ApplyGpu' \{ Apply-GpuLimits; return \}") 'The user-facing Apply action must use the readable/runnable task without a second UAC path.'
Assert-True ($controlPanel -match 'Get-ScheduledTask -TaskName \$presenceTaskName -ErrorAction SilentlyContinue') 'HUD-only installs must tolerate an absent optional camera task.'

$blockedWithoutRisk = $false
try {
    & $installPath -GpuIndexList '0' -MaxGraphicsClockMHz 1700 -PowerLimitWatts 280 2>$null
}
catch {
    $blockedWithoutRisk = $_.Exception.Message -match 'opt-in'
}
Assert-True $blockedWithoutRisk 'The installer must fail before elevation or hardware access when acknowledgement is absent.'

[pscustomobject]@{
    Status              = 'Passed'
    ExplicitTargets     = $true
    PreflightBeforeWrite = $true
    BestEffortRollback  = $true
    ProtectedTaskSource = $true
    ControlPanelUsesTask = $true
    CombinedDefaultsSafe = $true
}
