[CmdletBinding()]
param(
    [string]$InputRoot = 'C:\CA\Input',
    [string]$ResultsRoot = 'C:\CA\Results',

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^\\/:*?"<>|]+\.zip$')]
    [string]$PackageFileName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$ExpectedVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resultPath = Join-Path $ResultsRoot 'clean-machine-result.json'
$workRoot = Join-Path ([IO.Path]::GetTempPath()) ('ca-clean-machine-' + [Guid]::NewGuid().ToString('N'))
$installedTaskName = 'CA System Overlay'
$result = [ordered]@{
    schemaVersion = 1
    timestampUtc = [DateTime]::UtcNow.ToString('o')
    status = 'failed'
    packageVersion = $ExpectedVersion
    windowsVersion = [Environment]::OSVersion.Version.ToString()
    architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    verifierStatus = 'not-run'
    packageSha256 = $null
    installedTaskRunLevel = $null
    installedTriggerCount = 0
    installedExecutable = $false
    installedControlPanel = $false
    installedShortcut = $false
    uninstallTaskRemoved = $false
    uninstallFilesRemoved = $false
    uninstallShortcutRemoved = $false
    hardwareWrites = $false
    networkRequired = $false
    failureCode = $null
}

function Write-Result {
    New-Item -ItemType Directory -Path $ResultsRoot -Force | Out-Null
    $temporary = $resultPath + '.tmp'
    $result.timestampUtc = [DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $resultPath -Force
}

try {
    if (-not [string]::Equals([IO.Path]::GetFileName($PackageFileName), $PackageFileName, [StringComparison]::Ordinal)) {
        throw 'PackageFileName must be a leaf filename.'
    }
    $packagePath = Join-Path $InputRoot $PackageFileName
    $checksumPath = [IO.Path]::ChangeExtension($packagePath, '.sha256')
    $verifierPath = Join-Path $InputRoot 'Verify-DesktopPackage.ps1'
    foreach ($path in @($packagePath, $checksumPath, $verifierPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'sandbox-input-missing' }
    }

    $verification = & $verifierPath -PackagePath $packagePath -ChecksumPath $checksumPath -ExpectedVersion $ExpectedVersion
    if ([string]$verification.Status -ne 'Verified' -or [bool]$verification.HardwareWrites -or [bool]$verification.NetworkAccess -or [bool]$verification.ExtractedFiles) {
        throw 'package-verification-failed'
    }
    $result.verifierStatus = 'verified'
    $result.packageSha256 = [string]$verification.Sha256

    New-Item -ItemType Directory -Path $workRoot | Out-Null
    Expand-Archive -LiteralPath $packagePath -DestinationPath $workRoot
    $desktopExe = Join-Path $workRoot 'CAAutoConfig.exe'
    $installScript = Join-Path $workRoot 'Install-DesktopApp.ps1'
    $uninstallScript = Join-Path $workRoot 'Uninstall-SystemOverlay.ps1'
    foreach ($path in @($desktopExe, $installScript, $uninstallScript)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'expanded-package-incomplete' }
    }

    $smokePath = Join-Path $workRoot 'desktop-smoke.json'
    $smoke = Start-Process -FilePath $desktopExe -ArgumentList @('--smoke-test-result', ('"{0}"' -f $smokePath)) -WindowStyle Hidden -Wait -PassThru
    if ($smoke.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $smokePath -PathType Leaf)) { throw 'desktop-smoke-failed' }
    $smokeResult = Get-Content -Raw -LiteralPath $smokePath | ConvertFrom-Json
    if ([string]$smokeResult.status -ne 'passed' -or [bool]$smokeResult.hardwareWrites) { throw 'desktop-smoke-unsafe' }

    & $installScript -ExecutablePath $desktopExe | Out-Null
    $task = Get-ScheduledTask -TaskName $installedTaskName -ErrorAction Stop
    $installPath = Join-Path $env:LOCALAPPDATA 'CASystemOverlay'
    $installedExecutablePath = Join-Path $installPath 'CAAutoConfig.exe'
    $installedControlPanelPath = Join-Path $installPath 'CA-ControlPanel.ps1'
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CA AutoConfig.lnk'
    $result.installedTaskRunLevel = [string]$task.Principal.RunLevel
    $result.installedTriggerCount = @($task.Triggers).Count
    $result.installedExecutable = Test-Path -LiteralPath $installedExecutablePath -PathType Leaf
    $result.installedControlPanel = Test-Path -LiteralPath $installedControlPanelPath -PathType Leaf
    $result.installedShortcut = Test-Path -LiteralPath $shortcutPath -PathType Leaf
    $hasLogon = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }).Count -eq 1
    $hasUnlock = @($task.Triggers | Where-Object {
        $_.CimClass.CimClassName -eq 'MSFT_TaskSessionStateChangeTrigger' -and
        ([string]$_.StateChange -eq '8' -or [string]$_.StateChange -eq 'SessionUnlock')
    }).Count -eq 1
    $action = @($task.Actions)
    if ($result.installedTaskRunLevel -ne 'Limited' -or -not $hasLogon -or -not $hasUnlock -or $action.Count -ne 1 -or
        -not [string]::Equals([string]$action[0].Execute, $installedExecutablePath, [StringComparison]::OrdinalIgnoreCase) -or
        -not $result.installedExecutable -or -not $result.installedControlPanel -or -not $result.installedShortcut) {
        throw 'installed-state-invalid'
    }

    & $uninstallScript -RemoveFiles | Out-Null
    $result.uninstallTaskRemoved = $null -eq (Get-ScheduledTask -TaskName $installedTaskName -ErrorAction SilentlyContinue)
    $result.uninstallFilesRemoved = -not (Test-Path -LiteralPath $installPath)
    $result.uninstallShortcutRemoved = -not (Test-Path -LiteralPath $shortcutPath)
    if (-not $result.uninstallTaskRemoved -or -not $result.uninstallFilesRemoved -or -not $result.uninstallShortcutRemoved) {
        throw 'uninstall-state-invalid'
    }

    $result.status = 'passed'
    Write-Result
    exit 0
}
catch {
    $knownFailureCodes = @(
        'sandbox-input-missing',
        'package-verification-failed',
        'expanded-package-incomplete',
        'desktop-smoke-failed',
        'desktop-smoke-unsafe',
        'installed-state-invalid',
        'uninstall-state-invalid'
    )
    $message = [string]$_.Exception.Message
    $result.failureCode = if ($knownFailureCodes -contains $message) {
        $message
    }
    else {
        'unexpected-' + $_.Exception.GetType().Name.ToLowerInvariant()
    }
    Write-Result
    exit 1
}
finally {
    try {
        if ($null -ne (Get-ScheduledTask -TaskName $installedTaskName -ErrorAction SilentlyContinue)) {
            & (Join-Path $workRoot 'Uninstall-SystemOverlay.ps1') -RemoveFiles -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch { }
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolved = [IO.Path]::GetFullPath($workRoot)
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved -PathType Container)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
