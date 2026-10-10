[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GpuIndexList,

    [Parameter(Mandatory = $true)]
    [ValidateRange(300, 3000)]
    [int]$MaxGraphicsClockMHz,

    [Parameter(Mandatory = $true)]
    [ValidateRange(50, 1000)]
    [int]$PowerLimitWatts,

    [switch]$AcceptHardwareRisk,

    [string]$TargetUserName = '',

    [string]$TargetUserSid = '',

    [string]$ResolvedGpuUuidList = '',

    [string]$HelperPath = '',

    [string]$ExpectedHelperSha256 = '',

    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$applyTaskName = 'CA GPU Limits'
$resetTaskName = 'CA GPU Limits Reset'
$installPath = Join-Path $env:ProgramData 'CAGpuLimits'
$installedHelper = Join-Path $installPath 'CAGpuHelper.exe'
$statePath = Join-Path $installPath 'gpu-limits-state.json'
$rollbackPath = Join-Path $installPath 'gpu-limits-backup.json'
$installResultPath = Join-Path $installPath 'install-result.json'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$nvidiaSmi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

function Set-ProtectedInstallDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $administrators = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $security.SetOwner($administrators)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $rules = @(
        (New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, $propagation, $allow
        )),
        (New-Object Security.AccessControl.FileSystemAccessRule(
            $administrators,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, $propagation, $allow
        )),
        (New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance, $propagation, $allow
        ))
    )
    foreach ($rule in $rules) { [void]$security.AddAccessRule($rule) }
    (Get-Item -LiteralPath $Path -Force).SetAccessControl($security)
}

function Register-ProtectedGpuTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][bool]$AtLogon,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$SecurityDescriptor
    )

    $escapedDescription = [Security.SecurityElement]::Escape($Description)
    $escapedUser = [Security.SecurityElement]::Escape($UserName)
    $escapedSecurityDescriptor = [Security.SecurityElement]::Escape($SecurityDescriptor)
    $escapedHelper = [Security.SecurityElement]::Escape($installedHelper)
    $escapedArguments = [Security.SecurityElement]::Escape($Arguments)
    $escapedInstallPath = [Security.SecurityElement]::Escape($installPath)
    $triggerXml = if ($AtLogon) {
        $startLocal = (Get-Date).AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:ss')
@"
  <Triggers>
    <LogonTrigger>
      <StartBoundary>$startLocal</StartBoundary>
      <Delay>PT15S</Delay>
      <Enabled>true</Enabled>
      <UserId>$escapedUser</UserId>
    </LogonTrigger>
  </Triggers>
"@
    }
    else { '  <Triggers />' }

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$escapedDescription</Description>
    <SecurityDescriptor>$escapedSecurityDescriptor</SecurityDescriptor>
  </RegistrationInfo>
$triggerXml
  <Principals>
    <Principal id="System">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>4</Priority>
  </Settings>
  <Actions Context="System">
    <Exec>
      <Command>$escapedHelper</Command>
      <Arguments>$escapedArguments</Arguments>
      <WorkingDirectory>$escapedInstallPath</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    $tempXml = Join-Path ([IO.Path]::GetTempPath()) ("ca-gpu-task-{0}.xml" -f [Guid]::NewGuid().ToString('N'))
    try {
        $taskXml | Set-Content -LiteralPath $tempXml -Encoding Unicode
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $taskCreateOutput = (& schtasks.exe /Create /TN $TaskName /XML $tempXml /F 2>&1 | Out-String).Trim()
            $taskCreateExitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $oldPreference }
        if ($taskCreateExitCode -ne 0) {
            throw "Task Scheduler returned exit code ${taskCreateExitCode}: $taskCreateOutput"
        }

        $taskService = New-Object -ComObject 'Schedule.Service'
        $taskService.Connect()
        $registeredTask = $taskService.GetFolder('\').GetTask($TaskName)
        $registeredTask.SetSecurityDescriptor($SecurityDescriptor, 0)
        $actualDescriptor = [string]$registeredTask.GetSecurityDescriptor(4)
        if ($actualDescriptor -notmatch [regex]::Escape($UserSid)) {
            throw "Task Scheduler did not retain configured-user read/run access for '$TaskName'."
        }
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempXml
    }
}

if (-not $AcceptHardwareRisk) {
    throw 'GPU limits are opt-in. Review the selected cards, clock, and board-specific power range, then rerun with -AcceptHardwareRisk.'
}
if (-not $Elevated -and (-not [string]::IsNullOrWhiteSpace($ResolvedGpuUuidList) -or
    -not [string]::IsNullOrWhiteSpace($TargetUserName) -or
    -not [string]::IsNullOrWhiteSpace($TargetUserSid) -or
    -not [string]::IsNullOrWhiteSpace($ExpectedHelperSha256))) {
    throw 'Resolved UUID, target identity, and pinned-hash parameters are internal elevation handoff fields.'
}

$gpuIndexValues = @()
foreach ($token in @($GpuIndexList -split ',')) {
    $parsedIndex = 0
    if ([string]::IsNullOrWhiteSpace($token) -or -not [int]::TryParse($token.Trim(), [ref]$parsedIndex) -or $parsedIndex -lt 0) {
        throw "Invalid GPU index list '$GpuIndexList'. Use unique non-negative indices such as 0,1."
    }
    $gpuIndexValues += $parsedIndex
}
if (@($gpuIndexValues | Select-Object -Unique).Count -ne $gpuIndexValues.Count) {
    throw 'GPU indices must not contain duplicates.'
}
$gpuIndexArgument = $gpuIndexValues -join ','

if ([string]::IsNullOrWhiteSpace($HelperPath)) {
    $helperCandidates = @(
        (Join-Path $PSScriptRoot 'CAGpuHelper.exe'),
        (Join-Path $PSScriptRoot 'dist\gpu-helper-win-x64-self-contained\CAGpuHelper.exe')
    )
    $HelperPath = [string]($helperCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
}
if ([string]::IsNullOrWhiteSpace($HelperPath) -or -not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
    throw 'CAGpuHelper.exe is missing. Use the release bundle or run .\Build-GpuHelper.ps1 -SelfContained first.'
}
$HelperPath = [IO.Path]::GetFullPath($HelperPath)
if ($HelperPath.Contains('"')) { throw 'The GPU helper path contains an unsupported quote character.' }
$helperItem = Get-Item -LiteralPath $HelperPath -Force
if (($helperItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The GPU helper source must not be a reparse point.'
}
$actualHelperSha256 = (Get-FileHash -LiteralPath $HelperPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($ExpectedHelperSha256)) { $ExpectedHelperSha256 = $actualHelperSha256 }
if ($ExpectedHelperSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
    -not [string]::Equals($ExpectedHelperSha256, $actualHelperSha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The GPU helper hash changed or is invalid; refusing elevation.'
}

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ([string]::IsNullOrWhiteSpace($TargetUserName)) { $TargetUserName = $currentIdentity.Name }
if ([string]::IsNullOrWhiteSpace($TargetUserSid)) { $TargetUserSid = $currentIdentity.User.Value }
if ($TargetUserName.Contains('"')) { throw 'The target user name contains an unsupported quote character.' }
try { $resolvedTargetSid = ([Security.Principal.NTAccount]$TargetUserName).Translate([Security.Principal.SecurityIdentifier]).Value }
catch { throw "Could not resolve target user '$TargetUserName': $($_.Exception.Message)" }
if (-not [string]::Equals($resolvedTargetSid, $TargetUserSid, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The target user name and SID do not identify the same Windows account.'
}

$gpuUuidValues = @()
if ([string]::IsNullOrWhiteSpace($ResolvedGpuUuidList)) {
    if (-not (Test-Path -LiteralPath $nvidiaSmi -PathType Leaf)) { throw "nvidia-smi was not found: $nvidiaSmi" }
    foreach ($index in $gpuIndexValues) {
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $identityOutput = (& $nvidiaSmi -i $index --query-gpu=index,uuid --format=csv,noheader,nounits 2>&1 | Out-String).Trim()
            $identityExitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $oldPreference }
        $identityParts = @($identityOutput -split ',' | ForEach-Object { $_.Trim() })
        if ($identityExitCode -ne 0 -or $identityParts.Count -ne 2 -or [int]$identityParts[0] -ne $index -or
            $identityParts[1] -notmatch '^GPU-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$') {
            throw "Could not resolve a stable canonical UUID for GPU index $index."
        }
        $gpuUuidValues += [string]$identityParts[1]
    }
}
else {
    foreach ($token in @($ResolvedGpuUuidList -split ',')) {
        $uuid = $token.Trim()
        if ($uuid -notmatch '^GPU-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$') { throw 'Invalid resolved GPU UUID.' }
        $gpuUuidValues += $uuid
    }
}
if ($gpuUuidValues.Count -ne $gpuIndexValues.Count -or @($gpuUuidValues | Select-Object -Unique).Count -ne $gpuUuidValues.Count) {
    throw 'Resolved GPU UUIDs must be unique and match the approved GPU index count.'
}
$gpuUuidArgument = $gpuUuidValues -join ','

if (-not $isAdmin) {
    if ($Elevated) { throw 'Elevation was requested, but the process is still not running as Administrator.' }
    Write-Host 'Administrator approval is required. Accept the Windows UAC prompt.' -ForegroundColor Yellow
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
        '-GpuIndexList', $gpuIndexArgument,
        '-ResolvedGpuUuidList', $gpuUuidArgument,
        '-MaxGraphicsClockMHz', [string]$MaxGraphicsClockMHz,
        '-PowerLimitWatts', [string]$PowerLimitWatts,
        '-AcceptHardwareRisk',
        '-TargetUserName', ('"{0}"' -f $TargetUserName),
        '-TargetUserSid', $TargetUserSid,
        '-HelperPath', ('"{0}"' -f $HelperPath),
        '-ExpectedHelperSha256', $ExpectedHelperSha256,
        '-Elevated'
    ) -join ' '
    try {
        $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    }
    catch { throw "GPU helper installation was not elevated or was cancelled: $($_.Exception.Message)" }
    if ($process.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $installResultPath -PathType Leaf) { Get-Content -Raw -LiteralPath $installResultPath | Write-Host }
        throw "Elevated GPU helper installation failed with exit code $($process.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $installResultPath -PathType Leaf)) { throw 'Elevated installer completed without writing its result file.' }
    Get-Content -Raw -LiteralPath $installResultPath | ConvertFrom-Json | Format-List
    return
}

try {
    if (-not [string]::Equals((Get-FileHash -LiteralPath $HelperPath -Algorithm SHA256).Hash, $ExpectedHelperSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The GPU helper changed between validation and elevation.'
    }
    if (Test-Path -LiteralPath $installPath) {
        $existingInstallPath = Get-Item -LiteralPath $installPath -Force
        if (-not $existingInstallPath.PSIsContainer) { throw "GPU install path is not a directory: $installPath" }
        if (($existingInstallPath.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "GPU install path must not be a reparse point: $installPath" }
    }
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    Set-ProtectedInstallDirectory -Path $installPath

    $legacyTask = Get-ScheduledTask -TaskName $applyTaskName -ErrorAction SilentlyContinue
    if ($null -ne $legacyTask -and [string]$legacyTask.Actions.Execute -match 'powershell(?:\.exe)?$' -and
        -not (Test-Path -LiteralPath $rollbackPath -PathType Leaf) -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        try { $legacyState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json }
        catch { $legacyState = $null }
        if ($null -ne $legacyState -and [string]$legacyState.status -eq 'applied') {
            throw 'A legacy applied profile has no protected original-value record. Reset that profile first, then rerun this installer.'
        }
    }

    $stagedHelper = Join-Path $installPath ("CAGpuHelper-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $HelperPath -Destination $stagedHelper -Force
        if (-not [string]::Equals((Get-FileHash -LiteralPath $stagedHelper -Algorithm SHA256).Hash, $ExpectedHelperSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The staged GPU helper failed its pinned hash check.'
        }
        Move-Item -LiteralPath $stagedHelper -Destination $installedHelper -Force
    }
    finally { Remove-Item -LiteralPath $stagedHelper -Force -ErrorAction SilentlyContinue }

    $targetPairs = for ($i = 0; $i -lt $gpuIndexValues.Count; $i++) { '{0}={1}' -f $gpuIndexValues[$i], $gpuUuidValues[$i] }
    $applyArguments = 'apply --targets {0} --max-clock {1} --power-limit {2}' -f ($targetPairs -join ','), $MaxGraphicsClockMHz, $PowerLimitWatts
    $taskSecurityDescriptor = "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;$TargetUserSid)"

    Register-ProtectedGpuTask -TaskName $resetTaskName `
        -Description 'Restore the exact pre-apply NVIDIA power limits and vendor-managed graphics clocks from the protected rollback record.' `
        -Arguments 'reset' -AtLogon $false -UserName $TargetUserName -UserSid $TargetUserSid -SecurityDescriptor $taskSecurityDescriptor
    Register-ProtectedGpuTask -TaskName $applyTaskName `
        -Description "Apply the explicitly approved profile to GPU indices $gpuIndexArgument after the configured user logs on: ${MaxGraphicsClockMHz}MHz and ${PowerLimitWatts}W." `
        -Arguments $applyArguments -AtLogon $true -UserName $TargetUserName -UserSid $TargetUserSid -SecurityDescriptor $taskSecurityDescriptor

    $previousTimestamp = ''
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try { $previousTimestamp = [string](Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json).timestampUtc } catch { }
    }
    Start-ScheduledTask -TaskName $applyTaskName
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $gpuState = $null
    do {
        Start-Sleep -Milliseconds 400
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
        try {
            $candidate = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
            if ([string]$candidate.timestampUtc -ne $previousTimestamp) { $gpuState = $candidate }
        }
        catch { }
    } while ($null -eq $gpuState -and [DateTime]::UtcNow -lt $deadline)
    if ($null -eq $gpuState) { throw 'GPU helper task did not publish a fresh state within 30 seconds.' }
    if ([string]$gpuState.status -ne 'applied') { throw "GPU helper task reported failure: $($gpuState.message)" }

    $result = [ordered]@{
        timestampUtc         = [DateTime]::UtcNow.ToString('o')
        status               = 'installed'
        applyTaskName        = $applyTaskName
        resetTaskName        = $resetTaskName
        runAs                = 'SYSTEM'
        trigger              = 'Logon + 15 seconds'
        gpuIndices           = @($gpuIndexValues)
        gpuUuids             = @($gpuUuidValues)
        maxGraphicsClockMHz  = $MaxGraphicsClockMHz
        powerLimitWatts      = $PowerLimitWatts
        appliedNow           = $true
        helperSha256         = $ExpectedHelperSha256.ToLowerInvariant()
        rollbackPath         = $rollbackPath
        taskSecurityVerified = $true
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $installResultPath -Encoding UTF8
    $result | ConvertTo-Json -Depth 5
    exit 0
}
catch {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    $result = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status       = 'failed'
        message      = $_.Exception.Message
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $installResultPath -Encoding UTF8
    Write-Error $_.Exception.Message
    exit 1
}
