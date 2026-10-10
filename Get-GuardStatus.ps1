[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$Last = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'CA Unlock Guard'
$dataPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuard'
$configPath = Join-Path $dataPath 'config.json'
$eventPath = Join-Path $dataPath 'events.jsonl'
$alertPath = Join-Path $dataPath 'pending-alert.json'

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskInfo = if ($null -ne $task) { $task | Get-ScheduledTaskInfo } else { $null }

[pscustomobject]@{
    Installed    = ($null -ne $task)
    TaskState    = if ($null -ne $task) { [string]$task.State } else { 'NotFound' }
    LastTaskRun  = if ($null -ne $taskInfo) { $taskInfo.LastRunTime } else { $null }
    LastTaskCode = if ($null -ne $taskInfo) { $taskInfo.LastTaskResult } else { $null }
    ConfigPath   = $configPath
    PendingAlert = (Test-Path -LiteralPath $alertPath -PathType Leaf)
} | Format-List

if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    Write-Host 'Configuration:' -ForegroundColor Cyan
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $faceConfig = if ($null -ne $config.PSObject.Properties['Face']) { $config.Face } else { $null }
    [pscustomobject]@{
        Mode           = $config.Mode
        TimeoutSeconds = $config.TimeoutSeconds
        FolderName     = $config.FolderName
        WebhookEnabled = -not [string]::IsNullOrWhiteSpace([string]$config.WebhookUrl)
        FaceEnrolled   = ($null -ne $faceConfig -and (Test-Path -LiteralPath ([string]$faceConfig.ModelPath) -PathType Leaf))
        CameraIndex    = if ($null -ne $faceConfig) { $faceConfig.CameraIndex } else { $null }
    } | Format-List
}

if (Test-Path -LiteralPath $alertPath -PathType Leaf) {
    Write-Host 'Pending alert:' -ForegroundColor Yellow
    Get-Content -Raw -LiteralPath $alertPath | ConvertFrom-Json | Format-List
}

if (Test-Path -LiteralPath $eventPath -PathType Leaf) {
    Write-Host "Last $Last events:" -ForegroundColor Cyan
    Get-Content -LiteralPath $eventPath -Tail $Last | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $_ }
    } | Format-Table timestampUtc, event, machine, user -AutoSize
}
