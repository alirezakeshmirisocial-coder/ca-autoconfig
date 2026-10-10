[CmdletBinding()]
param(
    [ValidateRange(1, 168)]
    [double]$DurationHours = 24,

    [ValidateSet('SFace', 'LBPH')]
    [string]$Engine = 'SFace',

    [ValidateRange(0, 300)]
    [int]$IntervalSeconds = 0,

    [ValidateRange(0, 30)]
    [double]$BaselineSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'CA Presence Lab (NO LOCK)'
$labPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuardLab'
$runtimePython = Join-Path $labPath 'face-runtime\Scripts\python.exe'
$sourceRunner = Join-Path $PSScriptRoot 'Run-PresenceLab.ps1'
$labRunner = Join-Path $labPath 'Run-PresenceLab.ps1'
$statePath = Join-Path $labPath 'durable-run-state.json'
$errorLogPath = Join-Path $labPath 'durable-run-errors.log'
$runConfigPath = Join-Path $labPath 'durable-run.json'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if ($Engine -eq 'SFace') {
    $sourceFaceGuard = Join-Path $PSScriptRoot 'SFaceGuard.py'
    $labFaceGuard = Join-Path $labPath 'SFaceGuard.py'
    $modelPath = Join-Path $labPath 'sface-embeddings.npz'
    $profilePath = Join-Path $labPath 'sface-profile.json'
    $eventPath = Join-Path $labPath 'presence-events-sface-adaptive.jsonl'
    $yunetModelPath = Join-Path $labPath 'models\face_detection_yunet_2023mar.onnx'
    $sfaceModelPath = Join-Path $labPath 'models\face_recognition_sface_2021dec.onnx'
}
else {
    $sourceFaceGuard = Join-Path $PSScriptRoot 'FaceGuard.py'
    $labFaceGuard = Join-Path $labPath 'FaceGuard.py'
    $modelPath = Join-Path $labPath 'face-model.yml'
    $profilePath = Join-Path $labPath 'presence-profile.json'
    $eventPath = Join-Path $labPath 'presence-events.jsonl'
    $yunetModelPath = $null
    $sfaceModelPath = $null
}

foreach ($path in @($runtimePython, $sourceFaceGuard, $sourceRunner, $modelPath, $profilePath, $powerShellPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required Presence Lab component is missing: $path"
    }
}
if ($Engine -eq 'SFace') {
    $expectedModels = @(
        @{ Path = $yunetModelPath; Sha256 = '8F2383E4DD3CFBB4553EA8718107FC0423210DC964F9F4280604804ED2552FA4' },
        @{ Path = $sfaceModelPath; Sha256 = '0BA9FBFA01B5270C96627C4EF784DA859931E02F04419C829E83484087C34E79' }
    )
    foreach ($model in $expectedModels) {
        $path = [string]$model.Path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required SFace model is missing: $path. Run .\Start-SFacePresenceTest.ps1 -SetupOnly first."
        }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ne [string]$model.Sha256) {
            throw "SFace model failed SHA-256 verification: $path"
        }
    }
}

$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $existingTask) {
    if ([string]$existingTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        Start-Sleep -Milliseconds 500
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Copy-Item -Force -LiteralPath $sourceFaceGuard -Destination $labFaceGuard
Copy-Item -Force -LiteralPath $sourceRunner -Destination $labRunner

$profile = Get-Content -Raw -LiteralPath $profilePath | ConvertFrom-Json
if ($Engine -eq 'SFace') {
    if ([int]$profile.schemaVersion -lt 2 -or [string]$profile.engine -notlike '*Adaptive*') {
        throw 'The adaptive SFace profile is missing. Run .\Start-SFacePresenceTest.ps1 -SetupOnly first.'
    }
    $effectiveInterval = if ($BaselineSeconds -gt 0) { $BaselineSeconds } else { [double]$profile.baselineSeconds }
}
else {
    $effectiveInterval = if ($IntervalSeconds -gt 0) { $IntervalSeconds } else { [int]$profile.intervalSeconds }
    if ([double]$profile.scanSeconds -ge $effectiveInterval) {
        throw 'ScanSeconds must be shorter than IntervalSeconds.'
    }
}
$startUtc = [DateTimeOffset]::UtcNow
$endUtc = $startUtc.AddHours($DurationHours)
$runConfig = [ordered]@{
    SchemaVersion   = 2
    Engine          = $Engine
    TaskName        = $taskName
    StartUtc        = $startUtc.ToString('o')
    EndUtc          = $endUtc.ToString('o')
    PythonPath      = $runtimePython
    FaceGuardPath   = $labFaceGuard
    ModelPath       = $modelPath
    ProfilePath     = $profilePath
    EventPath       = $eventPath
    StatePath       = $statePath
    ErrorLogPath    = $errorLogPath
    CameraIndex     = [int]$profile.cameraIndex
    Threshold       = [double]$profile.threshold
    NoLock          = $true
}
if ($Engine -eq 'SFace') {
    $runConfig.Adaptive = $true
    $runConfig.YuNetModelPath = $yunetModelPath
    $runConfig.SFaceModelPath = $sfaceModelPath
    $runConfig.DetectionThreshold = [double]$profile.detectionThreshold
    $runConfig.BaselineSeconds = [double]$effectiveInterval
    $runConfig.CautiousSeconds = [double]$profile.cautiousSeconds
    $runConfig.WarningAfterSeconds = [double]$profile.warningAfterSeconds
    $runConfig.BurstIntervalSeconds = [double]$profile.burstIntervalSeconds
    $runConfig.BurstSamples = [int]$profile.burstSamples
    $runConfig.RecoveryMatches = [int]$profile.recoveryMatches
    $runConfig.StableMargin = [double]$profile.stableMargin
    $runConfig.OpenCvThreads = [int]$profile.openCvThreads
}
else {
    $runConfig.Adaptive = $false
    $runConfig.IntervalSeconds = [int]$effectiveInterval
    $runConfig.ScanSeconds = [int]$profile.scanSeconds
}
$runConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $runConfigPath -Encoding UTF8

$userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$startLocal = (Get-Date).AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:ss')
$endLocal = (Get-Date).AddHours($DurationHours).AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss')
$escapedUser = [Security.SecurityElement]::Escape($userName)
$escapedPowerShell = [Security.SecurityElement]::Escape($powerShellPath)
$escapedRunner = [Security.SecurityElement]::Escape($labRunner)
$escapedConfig = [Security.SecurityElement]::Escape($runConfigPath)
$escapedWorkingDirectory = [Security.SecurityElement]::Escape($labPath)
$arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;$escapedRunner&quot; -RunConfigPath &quot;$escapedConfig&quot;"

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Temporary adaptive CA Presence Lab ($Engine). This task cannot lock Windows.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <StartBoundary>$startLocal</StartBoundary>
      <EndBoundary>$endLocal</EndBoundary>
      <Enabled>true</Enabled>
      <UserId>$escapedUser</UserId>
    </LogonTrigger>
    <SessionStateChangeTrigger>
      <StartBoundary>$startLocal</StartBoundary>
      <EndBoundary>$endLocal</EndBoundary>
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
    <ExecutionTimeLimit>PT$([Math]::Ceiling($DurationHours + 2))H</ExecutionTimeLimit>
    <Priority>4</Priority>
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

$tempXml = Join-Path ([IO.Path]::GetTempPath()) ("ca-presence-lab-{0}.xml" -f [Guid]::NewGuid().ToString('N'))
try {
    $taskXml | Set-Content -LiteralPath $tempXml -Encoding Unicode
    & schtasks.exe /Create /TN $taskName /XML $tempXml /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Task Scheduler returned exit code $LASTEXITCODE while creating the lab task."
    }
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempXml
}

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
$task = Get-ScheduledTask -TaskName $taskName
$taskInfo = Get-ScheduledTaskInfo -TaskName $taskName

[pscustomobject]@{
    TaskName       = $taskName
    State          = $task.State
    StartLocal     = $startUtc.ToLocalTime().ToString('o')
    EndLocal       = $endUtc.ToLocalTime().ToString('o')
    LastTaskResult = $taskInfo.LastTaskResult
    Engine          = $Engine
    Sampling        = $(if ($Engine -eq 'SFace') { "Adaptive: baseline every $effectiveInterval seconds" } else { "Every $effectiveInterval seconds" })
    NoLock         = $true
    RunConfig      = $runConfigPath
} | Format-List
