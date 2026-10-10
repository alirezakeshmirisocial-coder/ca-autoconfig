[CmdletBinding()]
param(
    [ValidateRange(300, 3000)]
    [int]$MaxGraphicsClockMHz = 1700,

    [ValidateRange(50, 1000)]
    [int]$PowerLimitWatts = 280,

    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'CA GPU Limits'
$installPath = Join-Path $env:ProgramData 'CAGpuLimits'
$installedApply = Join-Path $installPath 'Apply-GpuLimits.ps1'
$logPath = Join-Path $installPath 'gpu-limits.log'
$statePath = Join-Path $installPath 'gpu-limits-state.json'
$installResultPath = Join-Path $installPath 'install-result.json'
$sourceApply = Join-Path $PSScriptRoot 'Apply-GpuLimits.ps1'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    if ($Elevated) {
        throw 'Elevation was requested, but the process is still not running as Administrator.'
    }
    Write-Host 'Administrator approval is required. Accept the Windows UAC prompt.' -ForegroundColor Yellow
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-MaxGraphicsClockMHz', [string]$MaxGraphicsClockMHz,
        '-PowerLimitWatts', [string]$PowerLimitWatts,
        '-Elevated'
    ) -join ' '
    try {
        $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    }
    catch {
        throw "GPU limit installation was not elevated or was cancelled: $($_.Exception.Message)"
    }
    if ($process.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $installResultPath -PathType Leaf) {
            Get-Content -Raw -LiteralPath $installResultPath | Write-Host
        }
        throw "Elevated GPU limit installation failed with exit code $($process.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $installResultPath -PathType Leaf)) {
        throw 'Elevated installer completed without writing its result file.'
    }
    Get-Content -Raw -LiteralPath $installResultPath | ConvertFrom-Json | Format-List
    return
}

try {
    if (-not (Test-Path -LiteralPath $sourceApply -PathType Leaf)) {
        throw "GPU apply script is missing: $sourceApply"
    }
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    Copy-Item -Force -LiteralPath $sourceApply -Destination $installedApply

    $userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $escapedUser = [Security.SecurityElement]::Escape($userName)
    $escapedPowerShell = [Security.SecurityElement]::Escape($powerShellPath)
    $escapedScript = [Security.SecurityElement]::Escape($installedApply)
    $escapedLog = [Security.SecurityElement]::Escape($logPath)
    $escapedState = [Security.SecurityElement]::Escape($statePath)
    $escapedInstallPath = [Security.SecurityElement]::Escape($installPath)
    $startLocal = (Get-Date).AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:ss')
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;$escapedScript&quot; -MaxGraphicsClockMHz $MaxGraphicsClockMHz -PowerLimitWatts $PowerLimitWatts -LogPath &quot;$escapedLog&quot; -StatePath &quot;$escapedState&quot;"

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Apply NVIDIA limits to GPU 0 and 1 after the configured user logs on: max graphics clock ${MaxGraphicsClockMHz}MHz, power limit ${PowerLimitWatts}W.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <StartBoundary>$startLocal</StartBoundary>
      <Delay>PT15S</Delay>
      <Enabled>true</Enabled>
      <UserId>$escapedUser</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="System">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>4</Priority>
  </Settings>
  <Actions Context="System">
    <Exec>
      <Command>$escapedPowerShell</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>$escapedInstallPath</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    $tempXml = Join-Path ([IO.Path]::GetTempPath()) ("ca-gpu-limits-{0}.xml" -f [Guid]::NewGuid().ToString('N'))
    try {
        $taskXml | Set-Content -LiteralPath $tempXml -Encoding Unicode
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $taskCreateOutput = (& schtasks.exe /Create /TN $taskName /XML $tempXml /F 2>&1 | Out-String).Trim()
            $taskCreateExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldPreference
        }
        if ($taskCreateExitCode -ne 0) {
            throw "Task Scheduler returned exit code ${taskCreateExitCode}: $taskCreateOutput"
        }
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempXml
    }

    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $statePath
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $statePath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'GPU limit task did not write a state file within 20 seconds.'
    }
    $gpuState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ([string]$gpuState.status -ne 'applied') {
        throw "GPU limit task reported failure: $($gpuState.message)"
    }

    $result = [ordered]@{
        timestampUtc          = [DateTime]::UtcNow.ToString('o')
        status                = 'installed'
        taskName              = $taskName
        runAs                 = 'SYSTEM'
        trigger               = 'Logon + 15 seconds'
        gpuIndices            = @(0, 1)
        maxGraphicsClockMHz   = $MaxGraphicsClockMHz
        powerLimitWatts       = $PowerLimitWatts
        appliedNow            = $true
        statePath             = $statePath
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $installResultPath -Encoding UTF8
    $result | ConvertTo-Json -Depth 5
    exit 0
}
catch {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    $result = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status       = 'failed'
        message      = $_.Exception.Message
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $installResultPath -Encoding UTF8
    Write-Error $_.Exception.Message
    exit 1
}
