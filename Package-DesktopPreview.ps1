[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version = '0.2.4-alpha.2',

    [ValidateSet('win-x64')]
    [string]$Runtime = 'win-x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$distRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'dist'))
$packageName = "CA-AutoConfig-Desktop-v$Version-$Runtime"
$stagePath = [IO.Path]::GetFullPath((Join-Path $distRoot $packageName))
$zipPath = [IO.Path]::GetFullPath((Join-Path $distRoot ($packageName + '.zip')))
$checksumPath = [IO.Path]::GetFullPath((Join-Path $distRoot ($packageName + '.sha256')))
$distPrefix = $distRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $stagePath.StartsWith($distPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to package outside the dist directory: $stagePath"
}

$build = & (Join-Path $PSScriptRoot 'Build-DesktopApp.ps1') -Configuration Release -Runtime $Runtime -SelfContained
if ([string]$build.Status -ne 'Built' -or -not $build.SelfContained) {
    throw 'The self-contained desktop build did not complete.'
}

if (Test-Path -LiteralPath $stagePath) { Remove-Item -LiteralPath $stagePath -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stagePath | Out-Null
Copy-Item -LiteralPath $build.Executable -Destination (Join-Path $stagePath 'CAAutoConfig.exe')
foreach ($relativePath in @(
    'Install-DesktopApp.ps1',
    'Install-SystemOverlay.ps1',
    'Uninstall-SystemOverlay.ps1',
    'LICENSE',
    'PRIVACY.md',
    'SECURITY.md'
)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relativePath) -Destination (Join-Path $stagePath (Split-Path -Leaf $relativePath))
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs\DESKTOP_PREVIEW.md') -Destination (Join-Path $stagePath 'README.md')
$packagedReadme = Join-Path $stagePath 'README.md'
$packagedReadmeText = (Get-Content -Raw -LiteralPath $packagedReadme).Replace('../benchmark/', 'benchmark/')
Set-Content -LiteralPath $packagedReadme -Encoding UTF8 -Value $packagedReadmeText
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'benchmark') -Destination (Join-Path $stagePath 'benchmark') -Recurse
Set-Content -LiteralPath (Join-Path $stagePath 'VERSION') -Encoding ascii -Value $Version

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $stagePath '*') -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $checksumPath -Encoding ascii -NoNewline -Value "$hash *$(Split-Path -Leaf $zipPath)`n"

[pscustomobject]@{
    Status       = 'Packaged'
    Version      = $Version
    Runtime      = $Runtime
    Zip          = $zipPath
    SizeBytes    = (Get-Item -LiteralPath $zipPath).Length
    Sha256       = $hash
    ExecutableSha256 = $build.Sha256
}
