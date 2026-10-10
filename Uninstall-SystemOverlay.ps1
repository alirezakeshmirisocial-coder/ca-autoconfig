[CmdletBinding()]
param([switch]$RemoveFiles)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'CA System Overlay'
$installPath = Join-Path $env:LOCALAPPDATA 'CASystemOverlay'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    if ([string]$task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        Start-Sleep -Milliseconds 500
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
if ($RemoveFiles -and (Test-Path -LiteralPath $installPath -PathType Container)) {
    Remove-Item -LiteralPath $installPath -Recurse -Force
}
Write-Host 'CA System Overlay task removed.' -ForegroundColor Green
