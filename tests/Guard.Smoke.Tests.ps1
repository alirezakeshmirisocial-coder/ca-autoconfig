[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$guardPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Guard.ps1'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ca-guard-smoke-{0}" -f [Guid]::NewGuid().ToString('N'))
$desktopPath = Join-Path $testRoot 'Desktop'
$dataPath = Join-Path $testRoot 'Data'
$configPath = Join-Path $dataPath 'config.json'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Write-TestConfig {
    param([string]$InstallationId)
    if (-not (Test-Path -LiteralPath $dataPath)) {
        New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
    }
    [ordered]@{
        SchemaVersion  = 1
        InstallationId = $InstallationId
        Mode            = 'FolderDelete'
        TimeoutSeconds  = 30
        FolderName      = 'CA'
        WebhookUrl      = ''
        Code            = $null
        Face            = $null
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
}

function Start-HeadlessGuard {
    param([int]$TimeoutSeconds)
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $guardPath),
        '-ConfigPath', ('"{0}"' -f $configPath),
        '-DesktopPathOverride', ('"{0}"' -f $desktopPath),
        '-DataPathOverride', ('"{0}"' -f $dataPath),
        '-TimeoutSecondsOverride', $TimeoutSeconds,
        '-NoUi',
        '-NoLock'
    )
    Start-Process -FilePath $powerShellPath -ArgumentList $arguments -PassThru -WindowStyle Hidden
}

try {
    New-Item -ItemType Directory -Path $desktopPath, $dataPath -Force | Out-Null

    Write-Host '1/3 folder-delete success path'
    Write-TestConfig -InstallationId ([Guid]::NewGuid().ToString('N'))
    $process = Start-HeadlessGuard -TimeoutSeconds 5
    $challengePath = Join-Path $desktopPath 'CA'
    $markerPath = Join-Path $challengePath '.ca-guard.json'
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    Assert-True (Test-Path -LiteralPath $challengePath -PathType Container) 'Challenge folder was not created.'
    Assert-True (Test-Path -LiteralPath $markerPath -PathType Leaf) 'Challenge ownership marker was not ready.'
    [IO.Directory]::Delete($challengePath, $true)
    [void]$process.WaitForExit(5000)
    Assert-True $process.HasExited 'Success-path Guard process did not exit.'
    Assert-True ($process.ExitCode -eq 0) "Expected exit code 0, got $($process.ExitCode)."

    Write-Host '2/3 timeout path with lock suppressed'
    Write-TestConfig -InstallationId ([Guid]::NewGuid().ToString('N'))
    $process = Start-HeadlessGuard -TimeoutSeconds 1
    [void]$process.WaitForExit(5000)
    Assert-True $process.HasExited 'Timeout-path Guard process did not exit.'
    Assert-True ($process.ExitCode -eq 2) "Expected exit code 2, got $($process.ExitCode)."
    Assert-True (Test-Path -LiteralPath (Join-Path $dataPath 'pending-alert.json') -PathType Leaf) 'Pending alert was not created.'

    if (Test-Path -LiteralPath $challengePath) {
        [IO.Directory]::Delete($challengePath, $true)
    }
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath (Join-Path $dataPath 'pending-alert.json')

    Write-Host '3/3 collision path fails open and preserves user data'
    Write-TestConfig -InstallationId ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $challengePath -Force | Out-Null
    $userFile = Join-Path $challengePath 'user-data.txt'
    Set-Content -LiteralPath $userFile -Value 'preserve me' -Encoding UTF8
    $process = Start-HeadlessGuard -TimeoutSeconds 1
    [void]$process.WaitForExit(5000)
    Assert-True $process.HasExited 'Collision-path Guard process did not exit.'
    Assert-True ($process.ExitCode -eq 3) "Expected exit code 3, got $($process.ExitCode)."
    Assert-True (Test-Path -LiteralPath $userFile -PathType Leaf) 'Collision path modified pre-existing user data.'

    Write-Host 'All CA Unlock Guard smoke tests passed.' -ForegroundColor Green
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if (($resolvedTest + '\').StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTest)) {
        Remove-Item -Recurse -Force -LiteralPath $resolvedTest
    }
}
