[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PackagePath,

    [string]$ChecksumPath = '',

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$ExpectedVersion,

    [string]$OutputRoot = '',

    [switch]$Launch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$verifierPath = Join-Path $repositoryRoot 'Verify-DesktopPackage.ps1'
$runnerPath = Join-Path $PSScriptRoot 'Run-CleanMachineSandbox.ps1'
$package = [IO.Path]::GetFullPath($PackagePath)
if ([string]::IsNullOrWhiteSpace($ChecksumPath)) { $ChecksumPath = [IO.Path]::ChangeExtension($package, '.sha256') }
$checksum = [IO.Path]::GetFullPath($ChecksumPath)
foreach ($path in @($package, $checksum, $verifierPath, $runnerPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required clean-machine input is missing: $path" }
}

$verification = & $verifierPath -PackagePath $package -ChecksumPath $checksum -ExpectedVersion $ExpectedVersion
if ([string]$verification.Status -ne 'Verified') { throw 'The package did not pass the offline verifier.' }

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repositoryRoot ('artifacts\clean-machine-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
}
$output = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $output) { throw "OutputRoot already exists: $output" }
$inputFolder = Join-Path $output 'input'
$resultFolder = Join-Path $output 'results'
New-Item -ItemType Directory -Path $inputFolder,$resultFolder | Out-Null

Copy-Item -LiteralPath $package -Destination (Join-Path $inputFolder ([IO.Path]::GetFileName($package)))
Copy-Item -LiteralPath $checksum -Destination (Join-Path $inputFolder ([IO.Path]::GetFileName($checksum)))
Copy-Item -LiteralPath $verifierPath -Destination (Join-Path $inputFolder 'Verify-DesktopPackage.ps1')
Copy-Item -LiteralPath $runnerPath -Destination (Join-Path $inputFolder 'Run-CleanMachineSandbox.ps1')

$escapedInput = [Security.SecurityElement]::Escape($inputFolder)
$escapedResults = [Security.SecurityElement]::Escape($resultFolder)
$packageName = [IO.Path]::GetFileName($package)
$command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\CA\Input\Run-CleanMachineSandbox.ps1 -PackageFileName &quot;$packageName&quot; -ExpectedVersion &quot;$ExpectedVersion&quot;"
$configuration = @"
<Configuration>
  <VGpu>Disable</VGpu>
  <Networking>Disable</Networking>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <ProtectedClient>Enable</ProtectedClient>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$escapedInput</HostFolder>
      <SandboxFolder>C:\CA\Input</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$escapedResults</HostFolder>
      <SandboxFolder>C:\CA\Results</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>$command</Command>
  </LogonCommand>
</Configuration>
"@
$configPath = Join-Path $output 'CA-AutoConfig-Clean-Machine.wsb'
$configuration | Set-Content -LiteralPath $configPath -Encoding UTF8

$launched = $false
if ($Launch) {
    $sandbox = Get-Command WindowsSandbox.exe -ErrorAction SilentlyContinue
    if ($null -eq $sandbox) { throw 'Windows Sandbox is not installed or is unavailable on this host.' }
    Start-Process -FilePath $configPath | Out-Null
    $launched = $true
}

[pscustomobject][ordered]@{
    Status = 'Prepared'
    PackageVersion = $ExpectedVersion
    PackageSha256 = [string]$verification.Sha256
    Configuration = $configPath
    InputFolder = $inputFolder
    ResultFile = (Join-Path $resultFolder 'clean-machine-result.json')
    Networking = 'Disabled'
    Vgpu = 'Disabled'
    Clipboard = 'Disabled'
    InputReadOnly = $true
    Launched = $launched
}
