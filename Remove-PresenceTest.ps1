[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$localAppData = [IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\') + '\'
$labPath = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuardLab'))
if (-not (($labPath + '\').StartsWith($localAppData, [StringComparison]::OrdinalIgnoreCase))) {
    throw "Refusing to remove a path outside LocalAppData: $labPath"
}

if (Test-Path -LiteralPath $labPath) {
    Remove-Item -Recurse -Force -LiteralPath $labPath
    Write-Host "Removed the Presence Lab runtime and face profile: $labPath" -ForegroundColor Green
}
else {
    Write-Host 'Presence Lab data was not present.'
}
