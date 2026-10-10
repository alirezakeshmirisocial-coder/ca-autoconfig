$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$quickStartPath = Join-Path $root 'docs\QUICKSTART.md'
$readmePath = Join-Path $root 'README.md'
$releasePath = Join-Path $root 'docs\releases\v0.2.6-alpha.4.md'
$quickStart = Get-Content -LiteralPath $quickStartPath -Raw -Encoding UTF8
$readme = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8

function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }

$version = '0.2.6-alpha.4'
$tag = "v$version"
$archive = "CA-AutoConfig-Desktop-$tag-win-x64.zip"
$digest = "CA-AutoConfig-Desktop-$tag-win-x64.sha256"
$publishedHash = '0a71a120139bf10e36bdad1c816cbd07b9fbcac9651ef498ba214862b32f3b6d'
$downloadBase = "https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/releases/download/$tag"

Assert-True (Test-Path -LiteralPath $quickStartPath -PathType Leaf) 'Quick-start document is missing.'
foreach ($asset in @($archive, $digest, 'Verify-DesktopPackage.ps1')) {
    Assert-True $quickStart.Contains("$downloadBase/$asset") "Quick start does not link the exact $asset release asset."
    Assert-True $release.Contains("$downloadBase/$asset") "Release notes do not link the exact $asset release asset."
}
Assert-True ($quickStart.Contains($publishedHash) -and $readme.Contains($publishedHash) -and $release.Contains($publishedHash)) 'Published ZIP SHA-256 is inconsistent across onboarding surfaces.'
Assert-True ($readme.Contains('(docs/QUICKSTART.md)') -and $release.Contains('(https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/blob/main/docs/QUICKSTART.md)')) 'README or release notes do not link the quick start.'

$hashIndex = $quickStart.IndexOf('Get-FileHash', [StringComparison]::Ordinal)
$verifierUnblockIndex = $quickStart.IndexOf('Unblock-File -LiteralPath .\Verify-DesktopPackage.ps1', [StringComparison]::Ordinal)
$verifyIndex = $quickStart.IndexOf('.\Verify-DesktopPackage.ps1', $verifierUnblockIndex + 1, [StringComparison]::Ordinal)
$archiveUnblockIndex = $quickStart.IndexOf("Unblock-File -LiteralPath .\$archive", [StringComparison]::Ordinal)
$expandIndex = $quickStart.IndexOf('Expand-Archive', [StringComparison]::Ordinal)
$installIndex = $quickStart.IndexOf('.\Install-DesktopApp.ps1', [StringComparison]::Ordinal)
Assert-True ($hashIndex -ge 0 -and $hashIndex -lt $verifierUnblockIndex -and $verifierUnblockIndex -lt $verifyIndex -and $verifyIndex -lt $archiveUnblockIndex -and $archiveUnblockIndex -lt $expandIndex -and $expandIndex -lt $installIndex) 'Quick start does not preserve verify-before-extract-before-install ordering.'

Assert-True ($quickStart -match '(?i)unsigned' -and $quickStart -match '(?i)stop if any check fails') 'Unsigned-alpha or verification-failure boundary is missing.'
Assert-True ($quickStart -match '(?i)does not request administrator rights' -and $quickStart -match '(?i)does not.+camera' -and $quickStart -match '(?i)(does not|no).+change GPU') 'Default-install privilege, camera, or hardware-write boundary is missing.'
Assert-True ($quickStart.Contains('Ctrl+Alt+L') -and $quickStart -match '(?i)visual display map' -and $quickStart -match '(?i)shortcut and opacity') 'First-minute lock, monitor, or shortcut guidance is missing.'
Assert-True ($quickStart.Contains('.\Uninstall-SystemOverlay.ps1 -RemoveFiles')) 'Complete HUD removal command is missing.'
Assert-True ($quickStart -match '(?i)not a universal recommendation' -and $quickStart -match '(?i)never applies') 'Power-advisor non-universal and no-auto-apply boundaries are missing.'
Assert-True ($quickStart -notmatch '(?i)Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|\bcurl\b|\birm\b|ExecutionPolicy\s+Bypass') 'Quick start downloads or bypasses policy from an executable command.'

Write-Host '10 quick-start tests passed. Asset identity, verify-first ordering, first-run controls, removal, and default safety boundaries are present.' -ForegroundColor Cyan
