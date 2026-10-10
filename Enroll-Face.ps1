[CmdletBinding()]
param(
    [ValidateRange(-1, 20)]
    [int]$CameraIndex = -1,

    [ValidateRange(0.0, 150.0)]
    [double]$Threshold = 0,

    [ValidateRange(15, 100)]
    [int]$Samples = 36
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dataPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuard'
$configPath = Join-Path $dataPath 'config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'CA Unlock Guard is not installed.'
}

$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
if ([string]$config.Mode -ne 'CodeAndFace' -or $null -eq $config.Face) {
    throw 'The installed Guard is not configured for CodeAndFace mode.'
}
if ($Threshold -gt 0 -and $Threshold -lt 30) {
    throw 'Threshold must be 0 (keep current) or between 30 and 150.'
}

$effectiveCamera = if ($CameraIndex -ge 0) { $CameraIndex } else { [int]$config.Face.CameraIndex }
$effectiveThreshold = if ($Threshold -gt 0) { $Threshold } else { [double]$config.Face.Threshold }
$pythonPath = [string]$config.Face.PythonPath
$scriptPath = [string]$config.Face.ScriptPath
$modelPath = [string]$config.Face.ModelPath

foreach ($path in @($pythonPath, $scriptPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "A face component is missing: $path"
    }
}

Write-Host 'Face enrollment will open the camera. Keep only the owner in frame and move your head slowly.' -ForegroundColor Cyan
& $pythonPath $scriptPath enroll `
    --model $modelPath `
    --camera-index $effectiveCamera `
    --samples $Samples `
    --threshold $effectiveThreshold
if ($LASTEXITCODE -ne 0) {
    throw "Face enrollment was not completed (exit code $LASTEXITCODE). The prior model, if any, is unchanged."
}

$config.Face.CameraIndex = $effectiveCamera
$config.Face.Threshold = $effectiveThreshold
$config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
Write-Host 'Face enrollment completed successfully.' -ForegroundColor Green
