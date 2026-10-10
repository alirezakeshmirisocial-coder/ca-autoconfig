[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PackagePath,

    [string]$ChecksumPath = '',

    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$ExpectedVersion = '',

    [ValidateRange(1048576, 4294967296)]
    [long]$MaxTotalUncompressedBytes = 1073741824
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$package = [IO.Path]::GetFullPath($PackagePath)
if (-not (Test-Path -LiteralPath $package -PathType Leaf)) { throw "Package is missing: $package" }
if ([string]::IsNullOrWhiteSpace($ChecksumPath)) { $ChecksumPath = [IO.Path]::ChangeExtension($package, '.sha256') }
$checksum = [IO.Path]::GetFullPath($ChecksumPath)
if (-not (Test-Path -LiteralPath $checksum -PathType Leaf)) { throw "Checksum file is missing: $checksum" }

$checksumText = Get-Content -Raw -LiteralPath $checksum
$checksumMatch = [regex]::Match($checksumText, '\A(?<hash>[0-9A-Fa-f]{64}) \*(?<name>[^\\/\r\n]+)(?:\r?\n)?\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
if (-not $checksumMatch.Success) { throw 'Checksum file must contain exactly: <64 hex SHA-256> *<ZIP filename>.' }
$expectedFileName = [IO.Path]::GetFileName($package)
if (-not [string]::Equals($checksumMatch.Groups['name'].Value, $expectedFileName, [StringComparison]::Ordinal)) {
    throw 'Checksum filename does not match the selected package.'
}
$expectedHash = $checksumMatch.Groups['hash'].Value.ToLowerInvariant()
$actualHash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not [string]::Equals($expectedHash, $actualHash, [StringComparison]::Ordinal)) { throw 'Package SHA-256 does not match the checksum file.' }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($package)
try {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $files = New-Object 'System.Collections.Generic.Dictionary[string,System.IO.Compression.ZipArchiveEntry]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    [long]$totalUncompressed = 0
    foreach ($entry in $archive.Entries) {
        $name = ([string]$entry.FullName).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/', [StringComparison]::Ordinal) -or
            $name -match '^[A-Za-z]:' -or $name -match '[\x00-\x1F]' -or $name.Contains('//')) {
            throw "Unsafe ZIP entry path: $name"
        }
        $segments = @($name.TrimEnd('/') -split '/')
        if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -eq '.' -or $_ -eq '..' -or [string]::IsNullOrEmpty($_) }).Count -gt 0) {
            throw "Unsafe ZIP entry path: $name"
        }
        if (-not $seen.Add($name)) { throw "Duplicate ZIP entry: $name" }

        $unixType = (([int64]$entry.ExternalAttributes -shr 16) -band 0xF000)
        if ($unixType -eq 0xA000) { throw "Symbolic-link ZIP entry is not allowed: $name" }
        if ($name.EndsWith('/', [StringComparison]::Ordinal)) { continue }
        if ($entry.Length -lt 0 -or $entry.Length -gt $MaxTotalUncompressedBytes -or $totalUncompressed -gt ($MaxTotalUncompressedBytes - $entry.Length)) {
            throw 'Package exceeds the configured uncompressed-size limit.'
        }
        $totalUncompressed += $entry.Length
        $files.Add($name, $entry)
    }

    $required = @(
        'CAAutoConfig.exe',
        'CAGpuHelper.exe',
        'Get-GpuLimitPlan.ps1',
        'Install-DesktopApp.ps1',
        'Install-GpuLimits.ps1',
        'README.md',
        'VERSION'
    )
    foreach ($name in $required) {
        if (-not $files.ContainsKey($name)) { throw "Required package entry is missing: $name" }
    }

    $versionEntry = $files['VERSION']
    if ($versionEntry.Length -le 0 -or $versionEntry.Length -gt 128) { throw 'VERSION entry has an invalid size.' }
    $stream = $versionEntry.Open()
    try {
        $reader = New-Object IO.StreamReader -ArgumentList $stream, ([Text.Encoding]::ASCII), $false, 128, $true
        try { $version = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
    if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'VERSION entry is invalid.' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and
        -not [string]::Equals($version, $ExpectedVersion, [StringComparison]::Ordinal)) {
        throw "Package version '$version' does not match expected version '$ExpectedVersion'."
    }

    [pscustomobject][ordered]@{
        Status = 'Verified'
        Version = $version
        Sha256 = $actualHash
        PackageBytes = (Get-Item -LiteralPath $package).Length
        FileCount = $files.Count
        TotalUncompressedBytes = $totalUncompressed
        HardwareWrites = $false
        NetworkAccess = $false
        ExtractedFiles = $false
    }
}
finally { $archive.Dispose() }
