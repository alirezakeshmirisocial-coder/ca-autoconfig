[CmdletBinding()]
param(
    [ValidateRange(0, 20)]
    [int]$CameraIndex = 0,

    [ValidateRange(5, 300)]
    [int]$IntervalSeconds = 30,

    [ValidateRange(2, 30)]
    [int]$ScanSeconds = 6,

    [ValidateRange(30.0, 150.0)]
    [double]$Threshold = 70.0,

    [ValidateRange(15, 100)]
    [int]$EnrollmentSamples = 36,

    [ValidateRange(0, 168)]
    [double]$DurationHours = 0,

    [switch]$ReEnroll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$labPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuardLab'
$runtimePath = Join-Path $labPath 'face-runtime'
$runtimePython = Join-Path $runtimePath 'Scripts\python.exe'
$labFaceGuard = Join-Path $labPath 'FaceGuard.py'
$labRequirements = Join-Path $labPath 'requirements-face.txt'
$modelPath = Join-Path $labPath 'face-model.yml'
$profilePath = Join-Path $labPath 'presence-profile.json'
$eventPath = Join-Path $labPath 'presence-events.jsonl'
$sourceFaceGuard = Join-Path $PSScriptRoot 'FaceGuard.py'
$sourceRequirements = Join-Path $PSScriptRoot 'requirements-face.txt'

function Get-SetupPython {
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
    throw 'Python 3.9+ is required for the presence lab.'
}

foreach ($source in @($sourceFaceGuard, $sourceRequirements)) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required lab file is missing: $source"
    }
}
if ($ScanSeconds -ge $IntervalSeconds) {
    throw 'ScanSeconds must be shorter than IntervalSeconds.'
}

if (-not (Test-Path -LiteralPath $labPath)) {
    New-Item -ItemType Directory -Path $labPath -Force | Out-Null
}
Copy-Item -Force -LiteralPath $sourceFaceGuard -Destination $labFaceGuard
Copy-Item -Force -LiteralPath $sourceRequirements -Destination $labRequirements

if (-not (Test-Path -LiteralPath $runtimePython -PathType Leaf)) {
    $setupPython = Get-SetupPython
    Write-Host 'Creating the isolated Presence Lab runtime...'
    & $setupPython -m venv $runtimePath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create the lab runtime (exit code $LASTEXITCODE)."
    }
}

& $runtimePython -c 'import cv2; assert hasattr(cv2, "face")' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Installing the pinned OpenCV dependency (one-time download)...'
    & $runtimePython -m pip install --disable-pip-version-check --only-binary=:all: -r $labRequirements
    if ($LASTEXITCODE -ne 0) {
        throw "Could not install face dependencies (exit code $LASTEXITCODE)."
    }
}

& $runtimePython $labFaceGuard self-test | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "The local face engine self-test failed (exit code $LASTEXITCODE)."
}

if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
    $savedProfile = Get-Content -Raw -LiteralPath $profilePath | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('CameraIndex')) { $CameraIndex = [int]$savedProfile.cameraIndex }
    if (-not $PSBoundParameters.ContainsKey('IntervalSeconds')) { $IntervalSeconds = [int]$savedProfile.intervalSeconds }
    if (-not $PSBoundParameters.ContainsKey('ScanSeconds')) { $ScanSeconds = [int]$savedProfile.scanSeconds }
    if (-not $PSBoundParameters.ContainsKey('Threshold')) { $Threshold = [double]$savedProfile.threshold }
}

if ($ReEnroll -or -not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
    Write-Host ''
    Write-Host 'Enrollment is starting. Follow the front/left/right prompts in the camera window.' -ForegroundColor Cyan
    & $runtimePython $labFaceGuard enroll `
        --model $modelPath `
        --camera-index $CameraIndex `
        --samples $EnrollmentSamples `
        --threshold $Threshold
    if ($LASTEXITCODE -ne 0) {
        throw "Enrollment was not completed (exit code $LASTEXITCODE)."
    }
}

Write-Host ''
Write-Host 'PRESENCE LAB: no scheduled task is created and Windows will never be locked.' -ForegroundColor Yellow
Write-Host "A scan runs for $ScanSeconds seconds every $IntervalSeconds seconds."
if ($DurationHours -gt 0) {
    Write-Host "The lab will stop automatically after $DurationHours hours."
}
Write-Host 'Green=owner, Red=clear mismatch, Orange=uncertain quality/absence, Gray=camera failure.'
Write-Host 'Use +/- to tune threshold, Space to scan immediately, S to save, and Esc to quit.'

& $runtimePython $labFaceGuard presence-test `
    --model $modelPath `
    --profile $profilePath `
    --log $eventPath `
    --camera-index $CameraIndex `
    --threshold $Threshold `
    --interval $IntervalSeconds `
    --scan-seconds $ScanSeconds `
    --duration-hours $DurationHours

if ($LASTEXITCODE -ne 0) {
    throw "Presence Lab stopped with exit code $LASTEXITCODE."
}
