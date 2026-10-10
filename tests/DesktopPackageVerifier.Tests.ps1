[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$verifier = Join-Path $root 'Verify-DesktopPackage.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('ca-package-verifier-' + [Guid]::NewGuid().ToString('N'))
$passed = 0

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:passed++
    Write-Host "PASS $Name" -ForegroundColor Green
}

function New-FixturePackage {
    param(
        [string]$Name,
        [hashtable]$Overrides = @{},
        [string[]]$ExtraEntries = @()
    )
    $zipPath = Join-Path $temporaryRoot ($Name + '.zip')
    $checksumPath = Join-Path $temporaryRoot ($Name + '.sha256')
    $entries = [ordered]@{
        'CAAutoConfig.exe' = 'desktop'
        'CAGpuHelper.exe' = 'helper'
        'Get-GpuLimitPlan.ps1' = 'plan'
        'Install-DesktopApp.ps1' = 'install desktop'
        'Install-GpuLimits.ps1' = 'install gpu'
        'README.md' = 'readme'
        'VERSION' = '9.8.7-test.1'
    }
    foreach ($key in $Overrides.Keys) {
        if ($null -eq $Overrides[$key]) { $entries.Remove($key) } else { $entries[$key] = [string]$Overrides[$key] }
    }
    $archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($key in $entries.Keys) {
            $entry = $archive.CreateEntry($key, [IO.Compression.CompressionLevel]::Optimal)
            $writer = New-Object IO.StreamWriter -ArgumentList ($entry.Open()), (New-Object Text.UTF8Encoding($false))
            try { $writer.Write([string]$entries[$key]) } finally { $writer.Dispose() }
        }
        foreach ($name in $ExtraEntries) {
            $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $writer = New-Object IO.StreamWriter -ArgumentList ($entry.Open()), (New-Object Text.UTF8Encoding($false))
            try { $writer.Write('extra') } finally { $writer.Dispose() }
        }
    }
    finally { $archive.Dispose() }
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $checksumPath -Encoding ascii -NoNewline -Value "$hash *$(Split-Path -Leaf $zipPath)`n"
    return [pscustomobject]@{ Zip = $zipPath; Checksum = $checksumPath }
}

function Expect-Failure {
    param([scriptblock]$Body, [string]$Pattern)
    try { & $Body; throw 'Expected verifier failure did not occur.' }
    catch {
        if ($_.Exception.Message -eq 'Expected verifier failure did not occur.') { throw }
        Assert-True ($_.Exception.Message -match $Pattern) "Unexpected verifier error: $($_.Exception.Message)"
    }
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

    Test-Case 'valid package verifies without extraction' {
        $fixture = New-FixturePackage 'valid'
        $result = & $verifier -PackagePath $fixture.Zip -ChecksumPath $fixture.Checksum -ExpectedVersion '9.8.7-test.1'
        Assert-True ($result.Status -eq 'Verified' -and $result.FileCount -eq 7) 'Valid package summary is wrong.'
        Assert-True (-not $result.HardwareWrites -and -not $result.NetworkAccess -and -not $result.ExtractedFiles) 'Verifier reported an unsafe side effect.'
    }

    Test-Case 'hash mismatch is rejected before ZIP inspection' {
        $fixture = New-FixturePackage 'bad-hash'
        Add-Content -LiteralPath $fixture.Zip -Encoding ascii -Value 'tamper'
        Expect-Failure { & $verifier -PackagePath $fixture.Zip -ChecksumPath $fixture.Checksum } 'SHA-256'
    }

    Test-Case 'checksum cannot name a different package' {
        $fixture = New-FixturePackage 'wrong-name'
        $text = (Get-Content -Raw -LiteralPath $fixture.Checksum).Replace('wrong-name.zip', 'other.zip')
        Set-Content -LiteralPath $fixture.Checksum -Encoding ascii -NoNewline -Value $text
        Expect-Failure { & $verifier -PackagePath $fixture.Zip -ChecksumPath $fixture.Checksum } 'filename'
    }

    Test-Case 'checksum cannot contain extra records' {
        $fixture = New-FixturePackage 'extra-checksum-line'
        Add-Content -LiteralPath $fixture.Checksum -Encoding ascii -Value 'unexpected'
        Expect-Failure { & $verifier -PackagePath $fixture.Zip -ChecksumPath $fixture.Checksum } 'must contain exactly'
    }

    Test-Case 'path traversal is rejected' {
        $fixture = New-FixturePackage 'traversal' @{} @('../outside.txt')
        Expect-Failure { & $verifier -PackagePath $fixture.Zip -ChecksumPath $fixture.Checksum } 'Unsafe ZIP entry path'
    }

    Test-Case 'case-insensitive duplicate is rejected' {
        $fixture = New-FixturePackage 'duplicate' @{} @('version')
        Expect-Failure { & $verifier -PackagePath $fixture.Zip -ChecksumPath $fixture.Checksum } 'Duplicate ZIP entry'
    }

    Test-Case 'missing required entry is rejected' {
        $fixture = New-FixturePackage 'missing' @{ 'CAGpuHelper.exe' = $null }
        Expect-Failure { & $verifier -PackagePath $fixture.Zip -ChecksumPath $fixture.Checksum } 'Required package entry is missing'
    }

    Test-Case 'declared version mismatch is rejected' {
        $fixture = New-FixturePackage 'version'
        Expect-Failure { & $verifier -PackagePath $fixture.Zip -ChecksumPath $fixture.Checksum -ExpectedVersion '1.0.0' } 'does not match expected version'
    }

    Test-Case 'uncompressed size limit fails closed' {
        $large = 'x' * 1100000
        $fixture = New-FixturePackage 'oversize' @{ 'README.md' = $large }
        Expect-Failure { & $verifier -PackagePath $fixture.Zip -ChecksumPath $fixture.Checksum -MaxTotalUncompressedBytes 1048576 } 'uncompressed-size limit'
    }

    $source = Get-Content -Raw -LiteralPath $verifier
    Assert-True ($source -notmatch 'ExtractToDirectory|Expand-Archive|Invoke-WebRequest|Start-Process') 'Verifier source contains extraction, network, or process-launch behavior.'
    Write-Host "$passed desktop-package verifier tests passed. Fixtures stayed inside the temporary test directory." -ForegroundColor Cyan
}
finally {
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved -PathType Container)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
