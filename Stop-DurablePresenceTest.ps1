[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'CA Presence Lab (NO LOCK)'
$labPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuardLab'
$statePath = Join-Path $labPath 'durable-run-state.json'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($null -ne $task) {
    if ([string]$task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        Start-Sleep -Milliseconds 500
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

if (Test-Path -LiteralPath $labPath -PathType Container) {
    [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status       = 'stopped_manually'
        processId    = $null
        details      = @{ noLock = $true }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

Write-Host 'The durable Presence Lab task was stopped. Logs and the face profile were preserved.' -ForegroundColor Green
