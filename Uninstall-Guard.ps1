[CmdletBinding()]
param(
    [switch]$PurgeData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'CA Unlock Guard'
$dataPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuard'
$resolvedLocalAppData = [IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\') + '\'
$resolvedDataPath = [IO.Path]::GetFullPath($dataPath)

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed scheduled task: $taskName"
}
else {
    Write-Host "Scheduled task was not present: $taskName"
}

if ($PurgeData) {
    if (-not ($resolvedDataPath + '\').StartsWith($resolvedLocalAppData, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a path outside LocalAppData: $resolvedDataPath"
    }
    if (Test-Path -LiteralPath $resolvedDataPath) {
        Remove-Item -Recurse -Force -LiteralPath $resolvedDataPath
        Write-Host "Removed Guard files, logs, and alerts: $resolvedDataPath"
    }
}
else {
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath `
        (Join-Path $dataPath 'Guard.ps1'), `
        (Join-Path $dataPath 'config.json'), `
        (Join-Path $dataPath 'FaceGuard.py'), `
        (Join-Path $dataPath 'requirements-face.txt'), `
        (Join-Path $dataPath 'face-model.yml'), `
        (Join-Path $dataPath 'face-model.yml.json')

    $faceRuntimePath = Join-Path $dataPath 'face-runtime'
    if (Test-Path -LiteralPath $faceRuntimePath) {
        $resolvedFaceRuntime = [IO.Path]::GetFullPath($faceRuntimePath)
        if (-not ($resolvedFaceRuntime + '\').StartsWith($resolvedDataPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a face runtime outside Guard data: $resolvedFaceRuntime"
        }
        Remove-Item -Recurse -Force -LiteralPath $resolvedFaceRuntime
    }
    Write-Host "Removed Guard program and configuration. Logs were preserved in: $dataPath"
}

$desktopPath = [Environment]::GetFolderPath('Desktop')
$challengePath = Join-Path $desktopPath 'CA'
if (Test-Path -LiteralPath $challengePath -PathType Container) {
    $markerPath = Join-Path $challengePath '.ca-guard.json'
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        $entries = @(Get-ChildItem -Force -LiteralPath $challengePath)
        if ($entries.Count -eq 1 -and $entries[0].FullName -eq $markerPath) {
            Remove-Item -Force -LiteralPath $markerPath
            Remove-Item -LiteralPath $challengePath
            Write-Host 'Removed the empty CA challenge folder from Desktop.'
        }
        else {
            Write-Warning 'The CA folder contains additional data and was left untouched.'
        }
    }
}

Write-Host 'CA Unlock Guard is uninstalled.' -ForegroundColor Green
