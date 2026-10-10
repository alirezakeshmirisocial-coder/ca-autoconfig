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

    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'CA GPU Limits'
$installPath = Join-Path $env:ProgramData 'CAGpuLimits'
$installedApply = Join-Path $installPath 'Apply-GpuLimits.ps1'
$logPath = Join-Path $installPath 'gpu-limits.log'
$statePath = Join-Path $installPath 'gpu-limits-state.json'
$installResultPath = Join-Path $installPath 'install-result.json'
$sourceApply = Join-Path $PSScriptRoot 'Apply-GpuLimits.ps1'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ([string]::IsNullOrWhiteSpace($TargetUserName)) { $TargetUserName = $currentIdentity.Name }
if ([string]::IsNullOrWhiteSpace($TargetUserSid)) { $TargetUserSid = $currentIdentity.User.Value }
if ($TargetUserName.Contains('"')) { throw 'The target user name contains an unsupported quote character.' }
try {
    $resolvedTargetSid = ([Security.Principal.NTAccount]$TargetUserName).Translate([Security.Principal.SecurityIdentifier]).Value
}
catch {
    throw "Could not resolve target user '$TargetUserName': $($_.Exception.Message)"
}
if (-not [string]::Equals($resolvedTargetSid, $TargetUserSid, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The target user name and SID do not identify the same Windows account.'
}

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
            $inheritance,
            $propagation,
            $allow
        )),
        (New-Object Security.AccessControl.FileSystemAccessRule(
            $administrators,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow
        )),
        (New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance,
            $propagation,
            $allow
        ))
    )
    foreach ($rule in $rules) { [void]$security.AddAccessRule($rule) }
    (Get-Item -LiteralPath $Path -Force).SetAccessControl($security)
}

if (-not $AcceptHardwareRisk) {
    throw 'GPU limits are opt-in. Review the requested indices, clock, and board-specific power range, then rerun with -AcceptHardwareRisk.'
}
$gpuIndexValues = @()
foreach ($token in @($GpuIndexList -split ',')) {
    $parsedIndex = 0
    if ([string]::IsNullOrWhiteSpace($token) -or -not [int]::TryParse($token.Trim(), [ref]$parsedIndex)) {
        throw "Invalid GPU index list '$GpuIndexList'. Use a comma-separated list such as 0,1."
    }
    $gpuIndexValues += $parsedIndex
}
if (@($gpuIndexValues | Where-Object { $_ -lt 0 }).Count -gt 0) {
    throw 'GPU indices must be zero or greater.'
}
if (@($gpuIndexValues | Select-Object -Unique).Count -ne $gpuIndexValues.Count) {
    throw 'GPU indices must not contain duplicates.'
}
$gpuIndexArgument = $gpuIndexValues -join ','

if (-not $isAdmin) {
    if ($Elevated) {
        throw 'Elevation was requested, but the process is still not running as Administrator.'
    }
    Write-Host 'Administrator approval is required. Accept the Windows UAC prompt.' -ForegroundColor Yellow
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-GpuIndexList', $gpuIndexArgument,
        '-MaxGraphicsClockMHz', [string]$MaxGraphicsClockMHz,
        '-PowerLimitWatts', [string]$PowerLimitWatts,
        '-AcceptHardwareRisk',
        '-TargetUserName', ('"{0}"' -f $TargetUserName),
        '-TargetUserSid', $TargetUserSid,
        '-Elevated'
    ) -join ' '
    try {
        $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    }
    catch {
        throw "GPU limit installation was not elevated or was cancelled: $($_.Exception.Message)"
    }
    if ($process.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $installResultPath -PathType Leaf) {
            Get-Content -Raw -LiteralPath $installResultPath | Write-Host
        }
        throw "Elevated GPU limit installation failed with exit code $($process.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $installResultPath -PathType Leaf)) {
        throw 'Elevated installer completed without writing its result file.'
    }
    Get-Content -Raw -LiteralPath $installResultPath | ConvertFrom-Json | Format-List
    return
}

try {
    if (-not (Test-Path -LiteralPath $sourceApply -PathType Leaf)) {
        throw "GPU apply script is missing: $sourceApply"
    }
    if (Test-Path -LiteralPath $installPath) {
        $existingInstallPath = Get-Item -LiteralPath $installPath -Force
        if (-not $existingInstallPath.PSIsContainer) {
            throw "GPU install path exists but is not a directory: $installPath"
        }
        if (($existingInstallPath.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "GPU install path must not be a reparse point: $installPath"
        }
    }
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    Set-ProtectedInstallDirectory -Path $installPath
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $installedApply
    Copy-Item -Force -LiteralPath $sourceApply -Destination $installedApply

    $userName = $TargetUserName
    $userSid = $TargetUserSid
    $escapedUser = [Security.SecurityElement]::Escape($userName)
    $taskSecurityDescriptor = "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;$userSid)"
    $escapedTaskSecurityDescriptor = [Security.SecurityElement]::Escape($taskSecurityDescriptor)
    $escapedPowerShell = [Security.SecurityElement]::Escape($powerShellPath)
    $escapedScript = [Security.SecurityElement]::Escape($installedApply)
    $escapedLog = [Security.SecurityElement]::Escape($logPath)
    $escapedState = [Security.SecurityElement]::Escape($statePath)
    $escapedInstallPath = [Security.SecurityElement]::Escape($installPath)
    $startLocal = (Get-Date).AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:ss')
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;$escapedScript&quot; -GpuIndexList $gpuIndexArgument -MaxGraphicsClockMHz $MaxGraphicsClockMHz -PowerLimitWatts $PowerLimitWatts -LogPath &quot;$escapedLog&quot; -StatePath &quot;$escapedState&quot;"

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Apply explicitly approved NVIDIA limits to GPU indices $gpuIndexArgument after the configured user logs on: max graphics clock ${MaxGraphicsClockMHz}MHz, power limit ${PowerLimitWatts}W.</Description>
    <SecurityDescriptor>$escapedTaskSecurityDescriptor</SecurityDescriptor>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <StartBoundary>$startLocal</StartBoundary>
      <Delay>PT15S</Delay>
      <Enabled>true</Enabled>
      <UserId>$escapedUser</UserId>
    </LogonTrigger>
  </Triggers>
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
      <Command>$escapedPowerShell</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>$escapedInstallPath</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    $tempXml = Join-Path ([IO.Path]::GetTempPath()) ("ca-gpu-limits-{0}.xml" -f [Guid]::NewGuid().ToString('N'))
    try {
        $taskXml | Set-Content -LiteralPath $tempXml -Encoding Unicode
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $taskCreateOutput = (& schtasks.exe /Create /TN $taskName /XML $tempXml /F 2>&1 | Out-String).Trim()
            $taskCreateExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldPreference
        }
        if ($taskCreateExitCode -ne 0) {
            throw "Task Scheduler returned exit code ${taskCreateExitCode}: $taskCreateOutput"
        }

        # schtasks may apply a creator-only descriptor when the task principal is
        # SYSTEM. Re-apply the reviewed descriptor through the supported Task
        # Scheduler API, then read it back before reporting installation success.
        $taskService = New-Object -ComObject 'Schedule.Service'
        $taskService.Connect()
        $registeredTask = $taskService.GetFolder('\').GetTask($taskName)
        $registeredTask.SetSecurityDescriptor($taskSecurityDescriptor, 0)
        $actualTaskSecurityDescriptor = [string]$registeredTask.GetSecurityDescriptor(4)
        if ($actualTaskSecurityDescriptor -notmatch [regex]::Escape($userSid)) {
            throw 'Task Scheduler did not retain the configured user read/run access rule.'
        }
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempXml
    }

    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $statePath
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $statePath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'GPU limit task did not write a state file within 20 seconds.'
    }
    $gpuState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ([string]$gpuState.status -ne 'applied') {
        throw "GPU limit task reported failure: $($gpuState.message)"
    }

    $result = [ordered]@{
        timestampUtc          = [DateTime]::UtcNow.ToString('o')
        status                = 'installed'
        taskName              = $taskName
        runAs                 = 'SYSTEM'
        trigger               = 'Logon + 15 seconds'
        gpuIndices            = @($gpuIndexValues)
        maxGraphicsClockMHz   = $MaxGraphicsClockMHz
        powerLimitWatts       = $PowerLimitWatts
        appliedNow            = $true
        statePath             = $statePath
        taskSecurityVerified  = $true
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
