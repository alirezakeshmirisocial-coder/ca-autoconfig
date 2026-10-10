[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'CA Presence Monitor (NO LOCK)'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    if ([string]$task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        Start-Sleep -Milliseconds 500
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
Write-Host 'Persistent Presence Monitor removed. Profiles and logs were preserved.' -ForegroundColor Green
