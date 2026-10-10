[CmdletBinding()]
param(
    [string]$CompiledExecutablePath = '',
    [string]$TargetDeviceName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$taskName = 'CA System Overlay'
$installPath = Join-Path $env:LOCALAPPDATA 'CASystemOverlay'
$sourceOverlay = Join-Path $PSScriptRoot 'SystemOverlay.cs'
$sourceRunner = Join-Path $PSScriptRoot 'Start-SystemOverlay.ps1'
$installedOverlay = Join-Path $installPath 'SystemOverlay.cs'
$installedRunner = Join-Path $installPath 'Start-SystemOverlay.ps1'
$installedExecutable = Join-Path $installPath 'CAAutoConfig.exe'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$compiledMode = -not [string]::IsNullOrWhiteSpace($CompiledExecutablePath)

$requiredPaths = if ($compiledMode) { @($CompiledExecutablePath) } else { @($sourceOverlay, $sourceRunner, $powerShellPath) }
foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required System Overlay component is missing: $path"
    }
}

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$existingTargetDeviceName = ''
if ($null -ne $existing) {
    $existingArguments = [string]$existing.Actions[0].Arguments
    $targetMatch = [regex]::Match($existingArguments, '(?:--display|-TargetDeviceName)\s+(?:"(?<quoted>[^"]+)"|(?<plain>\S+))', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($targetMatch.Success) {
        $existingTargetDeviceName = if ($targetMatch.Groups['quoted'].Success) {
            $targetMatch.Groups['quoted'].Value
        }
        else {
            $targetMatch.Groups['plain'].Value
        }
    }
}
$screens = @([System.Windows.Forms.Screen]::AllScreens)
$attachedDeviceNames = @($screens | ForEach-Object { [string]$_.DeviceName })
if (-not [string]::IsNullOrWhiteSpace($TargetDeviceName)) {
    if ($TargetDeviceName -notin $attachedDeviceNames) {
        throw "The requested display is not currently attached: $TargetDeviceName"
    }
    $targetDeviceName = $TargetDeviceName
}
elseif (-not [string]::IsNullOrWhiteSpace($existingTargetDeviceName) -and $existingTargetDeviceName -in $attachedDeviceNames) {
    $targetDeviceName = $existingTargetDeviceName
}
elseif ($screens.Count -ge 3) {
    $targetDeviceName = [string]$screens[2].DeviceName
}
elseif ($null -ne [System.Windows.Forms.Screen]::PrimaryScreen) {
    $targetDeviceName = [string][System.Windows.Forms.Screen]::PrimaryScreen.DeviceName
}
else {
    throw 'Windows did not report an attached display.'
}
if ($null -ne $existing) {
    if ([string]$existing.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        Start-Sleep -Milliseconds 700
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

New-Item -ItemType Directory -Force -Path $installPath | Out-Null
if ($compiledMode) {
    Copy-Item -Force -LiteralPath $CompiledExecutablePath -Destination $installedExecutable
}
else {
    Copy-Item -Force -LiteralPath $sourceOverlay -Destination $installedOverlay
    Copy-Item -Force -LiteralPath $sourceRunner -Destination $installedRunner
}
$userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$escapedUser = [Security.SecurityElement]::Escape($userName)
$escapedTargetDevice = [Security.SecurityElement]::Escape($targetDeviceName)
$escapedWorkingDirectory = [Security.SecurityElement]::Escape($installPath)
$startLocal = (Get-Date).AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:ss')
if ($compiledMode) {
    $command = [Security.SecurityElement]::Escape($installedExecutable)
    $arguments = "--display &quot;$escapedTargetDevice&quot;"
    $hostMode = '.NET 8 self-contained app'
}
else {
    $escapedPowerShell = [Security.SecurityElement]::Escape($powerShellPath)
    $escapedRunner = [Security.SecurityElement]::Escape($installedRunner)
    $command = $escapedPowerShell
    $arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;$escapedRunner&quot; -TargetDeviceName &quot;$escapedTargetDevice&quot;"
    $hostMode = 'Windows PowerShell compatibility host'
}

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Lightweight configurable CA hardware HUD with per-monitor placement and power telemetry.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <StartBoundary>$startLocal</StartBoundary>
      <Enabled>true</Enabled>
      <UserId>$escapedUser</UserId>
    </LogonTrigger>
    <SessionStateChangeTrigger>
      <StartBoundary>$startLocal</StartBoundary>
      <Enabled>true</Enabled>
      <StateChange>SessionUnlock</StateChange>
      <UserId>$escapedUser</UserId>
    </SessionStateChangeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$escapedUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
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
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$command</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>$escapedWorkingDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$tempXml = Join-Path ([IO.Path]::GetTempPath()) ("ca-system-overlay-{0}.xml" -f [Guid]::NewGuid().ToString('N'))
try {
    $taskXml | Set-Content -LiteralPath $tempXml -Encoding Unicode
    & schtasks.exe /Create /TN $taskName /XML $tempXml /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Task Scheduler returned exit code $LASTEXITCODE while creating the overlay task."
    }
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempXml
}

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 3
$task = Get-ScheduledTask -TaskName $taskName
$info = Get-ScheduledTaskInfo -TaskName $taskName
[pscustomobject]@{
    TaskName       = $taskName
    State          = $task.State
    LastTaskResult = $info.LastTaskResult
    AutoStart      = 'Logon + SessionUnlock'
    HostMode       = $hostMode
    TargetDevice   = $targetDeviceName
    Position       = 'Configurable (default lower-left)'
    ClickThrough   = 'Locked by default; tiny lock control remains interactive'
    Settings       = (Join-Path $env:LOCALAPPDATA 'CAAutoConfig\settings.json')
    DefaultHotkey  = 'Ctrl+Alt+L'
    PollSeconds    = 2
} | Format-List
