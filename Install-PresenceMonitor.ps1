[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'CA Presence Monitor (NO LOCK)'
$oldTaskName = 'CA Presence Lab (NO LOCK)'
$labPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuardLab'
$runtimePython = Join-Path $labPath 'face-runtime\Scripts\python.exe'
$sourceGuard = Join-Path $PSScriptRoot 'SFaceGuard.py'
$sourceRunner = Join-Path $PSScriptRoot 'Run-PresenceLab.ps1'
$guardPath = Join-Path $labPath 'SFaceGuard.py'
$runnerPath = Join-Path $labPath 'Run-PresenceLab.ps1'
$modelPath = Join-Path $labPath 'sface-embeddings.npz'
$profilePath = Join-Path $labPath 'sface-profile.json'
$eventPath = Join-Path $labPath 'presence-events-sface-adaptive.jsonl'
$statePath = Join-Path $labPath 'persistent-run-state.json'
$errorLogPath = Join-Path $labPath 'persistent-run-errors.log'
$configPath = Join-Path $labPath 'persistent-run.json'
$yunetModelPath = Join-Path $labPath 'models\face_detection_yunet_2023mar.onnx'
$sfaceModelPath = Join-Path $labPath 'models\face_recognition_sface_2021dec.onnx'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

foreach ($path in @(
    $runtimePython, $sourceGuard, $sourceRunner, $modelPath, $profilePath,
    $yunetModelPath, $sfaceModelPath, $powerShellPath
)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required Presence Monitor component is missing: $path"
    }
}

$expectedModels = @(
    @{ Path = $yunetModelPath; Sha256 = '8F2383E4DD3CFBB4553EA8718107FC0423210DC964F9F4280604804ED2552FA4' },
    @{ Path = $sfaceModelPath; Sha256 = '0BA9FBFA01B5270C96627C4EF784DA859931E02F04419C829E83484087C34E79' }
)
foreach ($model in $expectedModels) {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $model.Path).Hash -ne $model.Sha256) {
        throw "Face model failed SHA-256 verification: $($model.Path)"
    }
}

Copy-Item -Force -LiteralPath $sourceGuard -Destination $guardPath
Copy-Item -Force -LiteralPath $sourceRunner -Destination $runnerPath
$profile = Get-Content -Raw -LiteralPath $profilePath | ConvertFrom-Json
if ([int]$profile.schemaVersion -lt 2 -or [string]$profile.engine -notlike '*Adaptive*') {
    throw 'An adaptive SFace profile is required.'
}

$config = [ordered]@{
    SchemaVersion          = 3
    Engine                 = 'SFace'
    Persistent             = $true
    TaskName               = $taskName
    PythonPath             = $runtimePython
    FaceGuardPath          = $guardPath
    ModelPath              = $modelPath
    ProfilePath            = $profilePath
    EventPath              = $eventPath
    StatePath              = $statePath
    ErrorLogPath           = $errorLogPath
    CameraIndex            = [int]$profile.cameraIndex
    Threshold              = [double]$profile.threshold
    NoLock                 = $true
    Adaptive               = $true
    YuNetModelPath         = $yunetModelPath
    SFaceModelPath         = $sfaceModelPath
    DetectionThreshold     = [double]$profile.detectionThreshold
    BaselineSeconds        = [double]$profile.baselineSeconds
    CautiousSeconds        = [double]$profile.cautiousSeconds
    WarningAfterSeconds    = [double]$profile.warningAfterSeconds
    BurstIntervalSeconds   = [double]$profile.burstIntervalSeconds
    BurstSamples           = [int]$profile.burstSamples
    RecoveryMatches        = [int]$profile.recoveryMatches
    StableMargin           = [double]$profile.stableMargin
    OpenCvThreads          = [int]$profile.openCvThreads
}
$config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8

foreach ($name in @($taskName, $oldTaskName)) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        if ([string]$task.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $name
            Start-Sleep -Milliseconds 500
        }
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
    }
}

$userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$escapedUser = [Security.SecurityElement]::Escape($userName)
$escapedPowerShell = [Security.SecurityElement]::Escape($powerShellPath)
$escapedRunner = [Security.SecurityElement]::Escape($runnerPath)
$escapedConfig = [Security.SecurityElement]::Escape($configPath)
$escapedWorkingDirectory = [Security.SecurityElement]::Escape($labPath)
$startLocal = (Get-Date).AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:ss')
$arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;$escapedRunner&quot; -RunConfigPath &quot;$escapedConfig&quot;"

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Persistent adaptive CA face-presence monitor. This task cannot lock Windows.</Description>
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
    <Priority>6</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedPowerShell</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>$escapedWorkingDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$tempXml = Join-Path ([IO.Path]::GetTempPath()) ("ca-presence-monitor-{0}.xml" -f [Guid]::NewGuid().ToString('N'))
try {
    $taskXml | Set-Content -LiteralPath $tempXml -Encoding Unicode
    & schtasks.exe /Create /TN $taskName /XML $tempXml /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Task Scheduler returned exit code $LASTEXITCODE while creating the monitor task."
    }
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempXml
}

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
$task = Get-ScheduledTask -TaskName $taskName
$info = Get-ScheduledTaskInfo -TaskName $taskName
[pscustomobject]@{
    TaskName       = $taskName
    State          = $task.State
    LastTaskResult = $info.LastTaskResult
    Persistent     = $true
    NoLock         = $true
    Config         = $configPath
} | Format-List
