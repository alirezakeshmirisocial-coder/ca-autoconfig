[CmdletBinding()]
param(
    [ValidateSet('CodeAndFace', 'Code', 'FolderDelete')]
    [string]$Mode = 'CodeAndFace',

    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 30,

    [string]$WebhookUrl = '',

    [ValidateRange(0, 20)]
    [int]$CameraIndex = 0,

    [ValidateRange(30.0, 150.0)]
    [double]$FaceThreshold = 70.0,

    [ValidateRange(15, 100)]
    [int]$EnrollmentSamples = 36,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'CA Unlock Guard'
$installPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuard'
$desktopPath = [Environment]::GetFolderPath('Desktop')
$challengePath = Join-Path $desktopPath 'CA'
$sourceGuard = Join-Path $PSScriptRoot 'Guard.ps1'
$sourceFaceGuard = Join-Path $PSScriptRoot 'FaceGuard.py'
$sourceFaceRequirements = Join-Path $PSScriptRoot 'requirements-face.txt'
$installedGuard = Join-Path $installPath 'Guard.ps1'
$installedFaceGuard = Join-Path $installPath 'FaceGuard.py'
$installedFaceRequirements = Join-Path $installPath 'requirements-face.txt'
$faceRuntimePath = Join-Path $installPath 'face-runtime'
$facePythonPath = Join-Path $faceRuntimePath 'Scripts\python.exe'
$faceModelPath = Join-Path $installPath 'face-model.yml'
$configPath = Join-Path $installPath 'config.json'
$builtInPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory = $true)][Security.SecureString]$Value)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function New-CodeConfig {
    param([Parameter(Mandatory = $true)][int]$MinimumLength)

    while ($true) {
        $firstSecure = Read-Host "Create a private CA Guard PIN/code ($MinimumLength+ characters; a separate value is recommended)" -AsSecureString
        $secondSecure = Read-Host 'Repeat the CA Guard code' -AsSecureString
        $first = Convert-SecureStringToPlainText -Value $firstSecure
        $second = Convert-SecureStringToPlainText -Value $secondSecure

        try {
            if ($first.Length -lt $MinimumLength) {
                Write-Warning "The Guard code must contain at least $MinimumLength characters."
                continue
            }
            if ($first -cne $second) {
                Write-Warning 'The two values do not match.'
                continue
            }

            $salt = New-Object byte[] 16
            $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
            try { $rng.GetBytes($salt) } finally { $rng.Dispose() }

            $iterations = 200000
            $derive = New-Object Security.Cryptography.Rfc2898DeriveBytes($first, $salt, $iterations)
            try { $hash = $derive.GetBytes(32) } finally { $derive.Dispose() }

            return [ordered]@{
                Algorithm  = 'PBKDF2-HMAC-SHA1'
                Iterations = $iterations
                Salt       = [Convert]::ToBase64String($salt)
                Hash       = [Convert]::ToBase64String($hash)
            }
        }
        finally {
            $first = $null
            $second = $null
        }
    }
}

function Get-PythonForFaceSetup {
    $pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($null -ne $pyLauncher) {
        $candidate = (& $pyLauncher.Source -3 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -First 1)
        $pythonLookupSucceeded = $?
        if ($pythonLookupSucceeded -and -not [string]::IsNullOrWhiteSpace($candidate)) {
            return [string]$candidate
        }
    }

    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($null -ne $python) {
        return $python.Source
    }
    throw 'Python 3 is required for CodeAndFace mode. Install Python 3.9+ or use -Mode Code.'
}

if (-not (Test-Path -LiteralPath $sourceGuard -PathType Leaf)) {
    throw "Guard.ps1 was not found next to the installer: $sourceGuard"
}
if (-not (Test-Path -LiteralPath $builtInPowerShell -PathType Leaf)) {
    throw "Windows PowerShell was not found: $builtInPowerShell"
}
if ($Mode -eq 'CodeAndFace') {
    if ($TimeoutSeconds -lt 15) {
        throw 'CodeAndFace mode requires at least a 15-second timeout.'
    }
    foreach ($requiredFile in @($sourceFaceGuard, $sourceFaceRequirements)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Face component was not found: $requiredFile"
        }
    }
}
if (Test-Path -LiteralPath $challengePath) {
    throw "A Desktop item named CA already exists. Rename or remove it before installation: $challengePath"
}
if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
    throw 'CA Unlock Guard is already configured. Use -Force to replace its configuration.'
}
if ($WebhookUrl -and -not [Uri]::IsWellFormedUriString($WebhookUrl, [UriKind]::Absolute)) {
    throw 'WebhookUrl must be an absolute HTTP or HTTPS URL.'
}
if ($WebhookUrl) {
    $uri = [Uri]$WebhookUrl
    if ($uri.Scheme -notin @('http', 'https')) {
        throw 'WebhookUrl must use HTTP or HTTPS.'
    }
}

$codeConfig = $null
if ($Mode -in @('Code', 'CodeAndFace')) {
    $minimumCodeLength = if ($Mode -eq 'CodeAndFace') { 4 } else { 8 }
    $codeConfig = New-CodeConfig -MinimumLength $minimumCodeLength
}

if (-not (Test-Path -LiteralPath $installPath)) {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
}
Copy-Item -Force -LiteralPath $sourceGuard -Destination $installedGuard

$faceConfig = $null
if ($Mode -eq 'CodeAndFace') {
    $setupPython = Get-PythonForFaceSetup
    Copy-Item -Force -LiteralPath $sourceFaceGuard -Destination $installedFaceGuard
    Copy-Item -Force -LiteralPath $sourceFaceRequirements -Destination $installedFaceRequirements

    if (-not (Test-Path -LiteralPath $facePythonPath -PathType Leaf)) {
        Write-Host 'Creating an isolated Python runtime for face recognition...'
        & $setupPython -m venv $faceRuntimePath
        if ($LASTEXITCODE -ne 0) {
            throw "Could not create the face runtime (exit code $LASTEXITCODE)."
        }
    }

    Write-Host 'Installing the pinned local face-recognition dependency...'
    & $facePythonPath -m pip install --disable-pip-version-check --only-binary=:all: -r $installedFaceRequirements
    if ($LASTEXITCODE -ne 0) {
        throw "Could not install face dependencies (exit code $LASTEXITCODE)."
    }

    Write-Host ''
    Write-Host 'Face enrollment will now open the camera. Keep only the owner in frame and move your head slowly.' -ForegroundColor Cyan
    & $facePythonPath $installedFaceGuard enroll `
        --model $faceModelPath `
        --camera-index $CameraIndex `
        --samples $EnrollmentSamples `
        --threshold $FaceThreshold
    if ($LASTEXITCODE -ne 0) {
        throw "Face enrollment was not completed (exit code $LASTEXITCODE). No scheduled task was registered."
    }

    $faceConfig = [ordered]@{
        PythonPath      = $facePythonPath
        ScriptPath      = $installedFaceGuard
        ModelPath       = $faceModelPath
        CameraIndex     = $CameraIndex
        Threshold       = $FaceThreshold
        RequiredMatches = 5
        WindowSize      = 8
    }
}

$config = [ordered]@{
    SchemaVersion  = 2
    InstallationId = [Guid]::NewGuid().ToString('N')
    Mode            = $Mode
    TimeoutSeconds  = $TimeoutSeconds
    FolderName      = 'CA'
    WebhookUrl      = $WebhookUrl
    Code            = $codeConfig
    Face            = $faceConfig
}
$config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8

$userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$escapedUser = [Security.SecurityElement]::Escape($userName)
$escapedPowerShell = [Security.SecurityElement]::Escape($builtInPowerShell)
$escapedGuard = [Security.SecurityElement]::Escape($installedGuard)
$escapedConfig = [Security.SecurityElement]::Escape($configPath)
$escapedWorkingDirectory = [Security.SecurityElement]::Escape($installPath)
$arguments = "-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;$escapedGuard&quot; -ConfigPath &quot;$escapedConfig&quot;"

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Creates the CA desktop challenge at logon/unlock and locks the workstation when verification is not completed.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$escapedUser</UserId>
    </LogonTrigger>
    <SessionStateChangeTrigger>
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
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT12M</ExecutionTimeLimit>
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

$tempXml = Join-Path ([IO.Path]::GetTempPath()) ("ca-unlock-guard-{0}.xml" -f [Guid]::NewGuid().ToString('N'))
try {
    $taskXml | Set-Content -LiteralPath $tempXml -Encoding Unicode
    & schtasks.exe /Create /TN $taskName /XML $tempXml /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Task Scheduler returned exit code $LASTEXITCODE."
    }
}
catch {
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $installedGuard, $configPath
    throw
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempXml
}

Write-Host ''
Write-Host 'CA Unlock Guard was installed successfully.' -ForegroundColor Green
Write-Host "Mode: $Mode"
Write-Host "Timeout: $TimeoutSeconds seconds"
Write-Host "Task: $taskName"
Write-Host "Data: $installPath"
if ($Mode -eq 'CodeAndFace') {
    Write-Host "Camera index: $CameraIndex"
    Write-Host "Face threshold: $FaceThreshold"
}
Write-Host 'Lock and unlock Windows once to verify the real trigger.'
