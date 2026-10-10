[CmdletBinding()]
param([switch]$Elevated)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskNames = @('CA GPU Limits', 'CA GPU Limits Reset')
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"
    $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "Elevated removal failed with exit code $($process.ExitCode)." }
    return
}
foreach ($taskName in $taskNames) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        if ([string]$task.State -eq 'Running') { Stop-ScheduledTask -TaskName $taskName }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}
Write-Host 'GPU apply/reset tasks removed. Current driver settings and protected rollback data remain until an explicit rollback or reboot.' -ForegroundColor Green
