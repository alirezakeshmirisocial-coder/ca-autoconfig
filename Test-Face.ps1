[CmdletBinding()]
param(
    [ValidateRange(2, 120)]
    [int]$TimeoutSeconds = 15
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

& ([string]$config.Face.PythonPath) ([string]$config.Face.ScriptPath) verify `
    --model ([string]$config.Face.ModelPath) `
    --camera-index ([int]$config.Face.CameraIndex) `
    --timeout $TimeoutSeconds `
    --threshold ([double]$config.Face.Threshold) `
    --required-matches ([int]$config.Face.RequiredMatches) `
    --window-size ([int]$config.Face.WindowSize)

if ($LASTEXITCODE -eq 0) {
    Write-Host 'Face verification succeeded.' -ForegroundColor Green
    exit 0
}

Write-Warning "Face verification did not succeed (exit code $LASTEXITCODE)."
exit $LASTEXITCODE
