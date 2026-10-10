[CmdletBinding()]
param(
    [ValidateRange(0, 20)]
    [int]$CameraIndex = 0,

    [ValidateRange(1, 30)]
    [double]$BaselineSeconds = 2,

    [ValidateRange(0.5, 10)]
    [double]$CautiousSeconds = 1,

    [ValidateRange(3, 30)]
    [double]$WarningAfterSeconds = 6,

    [ValidateRange(0.25, 3)]
    [double]$BurstIntervalSeconds = 0.5,

    [ValidateRange(5, 30)]
    [int]$BurstSamples = 10,

    [ValidateRange(1, 8)]
    [int]$OpenCvThreads = 2,

    [ValidateRange(0.10, 0.90)]
    [double]$Threshold = 0.45,

    [ValidateRange(15, 120)]
    [int]$EnrollmentSamples = 45,

    [ValidateRange(0, 168)]
    [double]$DurationHours = 0,

    [switch]$ReEnroll,
    [switch]$SetupOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$labPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuardLab'
$runtimePath = Join-Path $labPath 'face-runtime'
$runtimePython = Join-Path $runtimePath 'Scripts\python.exe'
$modelsPath = Join-Path $labPath 'models'
$labGuard = Join-Path $labPath 'SFaceGuard.py'
$sourceGuard = Join-Path $PSScriptRoot 'SFaceGuard.py'
$sourceRequirements = Join-Path $PSScriptRoot 'requirements-face.txt'
$labRequirements = Join-Path $labPath 'requirements-face.txt'
$yunetPath = Join-Path $modelsPath 'face_detection_yunet_2023mar.onnx'
$sfacePath = Join-Path $modelsPath 'face_recognition_sface_2021dec.onnx'
$modelPath = Join-Path $labPath 'sface-embeddings.npz'
$profilePath = Join-Path $labPath 'sface-profile.json'
$eventPath = Join-Path $labPath 'presence-events-sface-adaptive.jsonl'

function Get-SetupPython {
    $pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($null -ne $pyLauncher) {
        $candidate = (& $pyLauncher.Source -3 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -First 1)
        if ($? -and -not [string]::IsNullOrWhiteSpace($candidate)) {
            return [string]$candidate
        }
    }
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($null -ne $python) {
        return $python.Source
    }
    throw 'Python 3.9+ is required for the SFace Presence Lab.'
}

function Get-OpenCvModel {
    param(
        [Parameter(Mandatory = $true)][uri]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][long]$MinimumBytes,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )
    if ((Test-Path -LiteralPath $Destination -PathType Leaf) -and
        (Get-Item -LiteralPath $Destination).Length -ge $MinimumBytes) {
        $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
        if ($existingHash -eq $ExpectedSha256) {
            return
        }
    }
    $temporary = "$Destination.download"
    try {
        Write-Host "Downloading official OpenCV model: $([IO.Path]::GetFileName($Destination))"
        Invoke-WebRequest -Uri $Uri -OutFile $temporary -UseBasicParsing
        $download = Get-Item -LiteralPath $temporary
        if ($download.Length -lt $MinimumBytes) {
            throw "Downloaded model is unexpectedly small ($($download.Length) bytes)."
        }
        $downloadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $temporary).Hash
        if ($downloadHash -ne $ExpectedSha256) {
            throw "Downloaded model failed SHA-256 verification: $($download.Name)"
        }
        Move-Item -Force -LiteralPath $temporary -Destination $Destination
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $temporary
    }
}

foreach ($source in @($sourceGuard, $sourceRequirements)) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required lab file is missing: $source"
    }
}

New-Item -ItemType Directory -Path $labPath -Force | Out-Null
New-Item -ItemType Directory -Path $modelsPath -Force | Out-Null
Copy-Item -Force -LiteralPath $sourceGuard -Destination $labGuard
Copy-Item -Force -LiteralPath $sourceRequirements -Destination $labRequirements

if (-not (Test-Path -LiteralPath $runtimePython -PathType Leaf)) {
    $setupPython = Get-SetupPython
    Write-Host 'Creating the isolated Presence Lab runtime...'
    & $setupPython -m venv $runtimePath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create the lab runtime (exit code $LASTEXITCODE)."
    }
}

& $runtimePython -c 'import cv2; assert cv2.FaceDetectorYN_create; assert cv2.FaceRecognizerSF_create' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Installing the pinned OpenCV dependency (one-time download)...'
    & $runtimePython -m pip install --disable-pip-version-check --only-binary=:all: -r $labRequirements
    if ($LASTEXITCODE -ne 0) {
        throw "Could not install face dependencies (exit code $LASTEXITCODE)."
    }
}

Get-OpenCvModel `
    -Uri 'https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx' `
    -Destination $yunetPath `
    -MinimumBytes 100000 `
    -ExpectedSha256 '8F2383E4DD3CFBB4553EA8718107FC0423210DC964F9F4280604804ED2552FA4'
Get-OpenCvModel `
    -Uri 'https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx' `
    -Destination $sfacePath `
    -MinimumBytes 10000000 `
    -ExpectedSha256 '0BA9FBFA01B5270C96627C4EF784DA859931E02F04419C829E83484087C34E79'

& $runtimePython $labGuard self-test --yunet-model $yunetPath --sface-model $sfacePath | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "YuNet/SFace self-test failed (exit code $LASTEXITCODE)."
}

if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
    $savedProfile = Get-Content -Raw -LiteralPath $profilePath | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('CameraIndex')) { $CameraIndex = [int]$savedProfile.cameraIndex }
    if (-not $PSBoundParameters.ContainsKey('Threshold')) { $Threshold = [double]$savedProfile.threshold }
}

if ($ReEnroll -or -not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
    Write-Host ''
    Write-Host 'New SFace enrollment is starting. Follow the FRONT / LEFT / RIGHT prompts.' -ForegroundColor Cyan
    Write-Host 'Keep the turns moderate (about 20-30 degrees), matching your usual desk angle.' -ForegroundColor Cyan
    & $runtimePython $labGuard enroll `
        --yunet-model $yunetPath `
        --sface-model $sfacePath `
        --model $modelPath `
        --camera-index $CameraIndex `
        --samples $EnrollmentSamples
    if ($LASTEXITCODE -ne 0) {
        throw "SFace enrollment was not completed (exit code $LASTEXITCODE)."
    }
}

$profile = [ordered]@{
    schemaVersion        = 2
    engine               = 'OpenCV-YuNet-SFace-Adaptive'
    savedUtc             = [DateTime]::UtcNow.ToString('o')
    modelPath            = $modelPath
    cameraIndex          = $CameraIndex
    threshold            = $Threshold
    detectionThreshold   = 0.75
    baselineSeconds      = $BaselineSeconds
    cautiousSeconds      = $CautiousSeconds
    warningAfterSeconds  = $WarningAfterSeconds
    burstIntervalSeconds = $BurstIntervalSeconds
    burstSamples         = $BurstSamples
    recoveryMatches      = 3
    stableMargin         = 0.08
    openCvThreads        = $OpenCvThreads
    rawImagesStored      = $false
}
$profile | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $profilePath -Encoding UTF8

$modelFiles = @($yunetPath, $sfacePath) | ForEach-Object {
    $item = Get-Item -LiteralPath $_
    [pscustomobject]@{
        Name   = $item.Name
        Bytes  = $item.Length
        SHA256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash
    }
}
$modelFiles | Format-Table -AutoSize

if ($SetupOnly) {
    [pscustomobject]@{
        Engine          = 'OpenCV-YuNet-SFace-Adaptive'
        EnrollmentModel = $modelPath
        Profile          = $profilePath
        BaselineSeconds  = $BaselineSeconds
        CautiousSeconds  = $CautiousSeconds
        WarningAfter     = $WarningAfterSeconds
        BurstPlan        = "$BurstSamples samples, one every $BurstIntervalSeconds seconds"
        OpenCvThreads    = $OpenCvThreads
        NoLock           = $true
    } | Format-List
    return
}

Write-Host ''
Write-Host 'SFACE PRESENCE LAB: Windows will never be locked.' -ForegroundColor Yellow
Write-Host "Normal mode processes one frame every $BaselineSeconds seconds."
Write-Host "Weak evidence switches to every $CautiousSeconds second; after $WarningAfterSeconds seconds it warns and collects up to $BurstSamples confirmations."
Write-Host 'Green=owner, Red=clear mismatch, Orange=uncertain, Gray=camera failure.'
Write-Host 'For SFace, a HIGHER threshold is stricter. Use +/- to tune and S to save.'

& $runtimePython $labGuard adaptive-test `
    --yunet-model $yunetPath `
    --sface-model $sfacePath `
    --model $modelPath `
    --profile $profilePath `
    --log $eventPath `
    --camera-index $CameraIndex `
    --threshold $Threshold `
    --baseline-seconds $BaselineSeconds `
    --cautious-seconds $CautiousSeconds `
    --warning-after-seconds $WarningAfterSeconds `
    --burst-interval-seconds $BurstIntervalSeconds `
    --burst-samples $BurstSamples `
    --opencv-threads $OpenCvThreads `
    --duration-hours $DurationHours

if ($LASTEXITCODE -ne 0) {
    throw "SFace Presence Lab stopped with exit code $LASTEXITCODE."
}
