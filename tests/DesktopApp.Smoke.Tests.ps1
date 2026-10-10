[CmdletBinding()]
param([switch]$SelfContained)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $root 'Build-DesktopApp.ps1'
$resultRoot = Join-Path ([IO.Path]::GetTempPath()) ('ca-desktop-app-test-' + [Guid]::NewGuid().ToString('N'))
$resultPath = Join-Path $resultRoot 'result.json'

try {
    $build = & $buildScript -Configuration Release -SelfContained:$SelfContained
    if ([string]$build.Status -ne 'Built') { throw 'Compiled desktop app build did not report success.' }
    if (-not (Test-Path -LiteralPath $build.Executable -PathType Leaf)) { throw 'Compiled desktop executable is missing.' }
    New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
    $savedDotnetRoot = $env:DOTNET_ROOT
    if (-not $build.SelfContained) { $env:DOTNET_ROOT = $build.DotnetRoot }
    try {
        $process = Start-Process -FilePath $build.Executable -ArgumentList @('--smoke-test-result', ('"{0}"' -f $resultPath)) -WindowStyle Hidden -Wait -PassThru
    }
    finally {
        $env:DOTNET_ROOT = $savedDotnetRoot
    }
    if ($process.ExitCode -ne 0) {
        $detail = if (Test-Path -LiteralPath $resultPath -PathType Leaf) { Get-Content -Raw -LiteralPath $resultPath } else { 'no result file' }
        throw "Compiled desktop smoke process failed with exit code $($process.ExitCode): $detail"
    }
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'Compiled desktop smoke result is missing.' }
    $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
    if ([string]$result.status -ne 'passed' -or [int]$result.schemaVersion -ne 1 -or [bool]$result.hardwareWrites) {
        throw "Unexpected compiled desktop smoke result: $(Get-Content -Raw -LiteralPath $resultPath)"
    }
    [pscustomobject]@{
        Status        = 'Passed'
        Framework     = $build.Framework
        Executable    = $build.Executable
        SizeBytes     = $build.SizeBytes
        Sha256        = $build.Sha256
        SettingsSchema = [int]$result.schemaVersion
        HardwareWrites = [bool]$result.hardwareWrites
    }
}
finally {
    if (Test-Path -LiteralPath $resultRoot -PathType Container) {
        Remove-Item -LiteralPath $resultRoot -Recurse -Force
    }
}
