[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $root 'tools\New-CleanMachineSandbox.ps1'
$runner = Join-Path $root 'tools\Run-CleanMachineSandbox.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('ca-sandbox-generator-' + [Guid]::NewGuid().ToString('N'))
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
    $zipPath = Join-Path $temporaryRoot 'fixture.zip'
    $entries = [ordered]@{
        'CAAutoConfig.exe' = 'desktop'
        'CAGpuHelper.exe' = 'helper'
        'Get-GpuLimitPlan.ps1' = 'plan'
        'Install-DesktopApp.ps1' = 'install desktop'
        'Install-GpuLimits.ps1' = 'install gpu'
        'README.md' = 'readme'
        'VERSION' = '9.8.7-test.1'
    }
    $archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $entries.Keys) {
            $entry = $archive.CreateEntry($name)
            $writer = New-Object IO.StreamWriter -ArgumentList ($entry.Open()), (New-Object Text.UTF8Encoding($false))
            try { $writer.Write([string]$entries[$name]) } finally { $writer.Dispose() }
        }
    }
    finally { $archive.Dispose() }
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksum = [IO.Path]::ChangeExtension($zipPath, '.sha256')
    Set-Content -LiteralPath $checksum -Encoding ascii -NoNewline -Value "$hash *$(Split-Path -Leaf $zipPath)`n"
    return [pscustomobject]@{ Zip = $zipPath; Checksum = $checksum }
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $fixture = New-FixturePackage
    $outputRoot = Join-Path $temporaryRoot 'output & evidence'
    $prepared = & $generator -PackagePath $fixture.Zip -ChecksumPath $fixture.Checksum -ExpectedVersion '9.8.7-test.1' -OutputRoot $outputRoot

    Test-Case 'generator verifies package and does not launch by default' {
        Assert-True ($prepared.Status -eq 'Prepared' -and -not $prepared.Launched) 'Generator unexpectedly launched Windows Sandbox.'
        Assert-True ($prepared.PackageSha256 -match '^[0-9a-f]{64}$') 'Verified package digest is missing.'
        Assert-True (Test-Path -LiteralPath $prepared.Configuration -PathType Leaf) 'WSB configuration was not created.'
    }

    [xml]$xml = Get-Content -Raw -LiteralPath $prepared.Configuration
    Test-Case 'sandbox disables external surfaces' {
        Assert-True ($xml.Configuration.Networking -eq 'Disable' -and $xml.Configuration.VGpu -eq 'Disable') 'Network or vGPU was not disabled.'
        Assert-True ($xml.Configuration.AudioInput -eq 'Disable' -and $xml.Configuration.VideoInput -eq 'Disable' -and
            $xml.Configuration.PrinterRedirection -eq 'Disable' -and $xml.Configuration.ClipboardRedirection -eq 'Disable') 'A redirection surface was left enabled.'
    }

    Test-Case 'mapped package input is read-only and result scope is narrow' {
        $mapped = @($xml.Configuration.MappedFolders.MappedFolder)
        Assert-True ($mapped.Count -eq 2) 'Unexpected mapped-folder count.'
        Assert-True ($mapped[0].ReadOnly -eq 'true' -and $mapped[0].SandboxFolder -eq 'C:\CA\Input') 'Input mapping is not read-only.'
        Assert-True ($mapped[1].ReadOnly -eq 'false' -and $mapped[1].SandboxFolder -eq 'C:\CA\Results') 'Result mapping is not the only writable host scope.'
        Assert-True ($mapped[0].HostFolder -eq (Join-Path $outputRoot 'input')) 'XML escaping changed the input path.'
    }

    Test-Case 'fixed logon runner and evidence path are prepared' {
        Assert-True ([string]$xml.Configuration.LogonCommand.Command -match 'Run-CleanMachineSandbox\.ps1' -and
            [string]$xml.Configuration.LogonCommand.Command -match 'fixture\.zip') 'Logon command does not use the fixed runner/package.'
        Assert-True ((Split-Path -Parent $prepared.ResultFile) -eq (Join-Path $outputRoot 'results')) 'Evidence escaped the requested results folder.'
        foreach ($name in @('fixture.zip', 'fixture.sha256', 'Verify-DesktopPackage.ps1', 'Run-CleanMachineSandbox.ps1')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $outputRoot "input\$name") -PathType Leaf) "Prepared input is missing: $name"
        }
    }

    Test-Case 'harness source contains no feature enablement, network, or GPU mutation path' {
        $generatorSource = Get-Content -Raw -LiteralPath $generator
        $runnerSource = Get-Content -Raw -LiteralPath $runner
        Assert-True ($generatorSource -notmatch 'Enable-WindowsOptionalFeature' -and $generatorSource -match 'if \(\$Launch\)') 'Generator changes Windows features or launches implicitly.'
        Assert-True ($runnerSource -notmatch 'Invoke-WebRequest|Invoke-RestMethod|nvidia-smi|''-pl''|''-lgc''|''-rgc''') 'Sandbox runner contains a network or GPU-mutation operation.'
        Assert-True ($runnerSource -match 'Install-DesktopApp\.ps1' -and $runnerSource -match 'Uninstall-SystemOverlay\.ps1') 'Sandbox runner does not cover install and uninstall.'
        Assert-True ($runnerSource -match "StateChange -eq '8'" -and $runnerSource -notmatch 'Exception\.Message,') 'Runner must recognize the Task Scheduler unlock value and avoid exporting exception text.'
    }

    Write-Host "$passed clean-machine sandbox preparation tests passed. Windows Sandbox was not launched." -ForegroundColor Cyan
}
finally {
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved -PathType Container)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
