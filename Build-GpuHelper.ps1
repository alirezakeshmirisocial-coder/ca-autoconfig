[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateSet('win-x64')]
    [string]$Runtime = 'win-x64',

    [switch]$SelfContained
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectPath = Join-Path $PSScriptRoot 'src\CAAutoConfig.GpuHelper\CAAutoConfig.GpuHelper.csproj'
$localDotnet = Join-Path $PSScriptRoot '.tools\dotnet\dotnet.exe'
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnet = if ($null -ne $dotnetCommand) { $dotnetCommand.Source } elseif (Test-Path -LiteralPath $localDotnet -PathType Leaf) { $localDotnet } else { $null }
if ([string]::IsNullOrWhiteSpace($dotnet)) {
    throw 'The .NET 8 SDK was not found. Install it from https://dotnet.microsoft.com/download/dotnet/8.0 or into .tools\dotnet.'
}

$mode = if ($SelfContained) { 'self-contained' } else { 'framework-dependent' }
$outputPath = Join-Path $PSScriptRoot ("dist\gpu-helper-{0}-{1}" -f $Runtime, $mode)
$arguments = @(
    'publish', $projectPath,
    '--configuration', $Configuration,
    '--runtime', $Runtime,
    '--self-contained', $SelfContained.IsPresent.ToString().ToLowerInvariant(),
    '--output', $outputPath,
    '-p:PublishSingleFile=true',
    '-p:PublishTrimmed=false',
    '-p:DebugType=None',
    '-p:DebugSymbols=false'
)
& $dotnet @arguments | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }

$executable = Join-Path $outputPath 'CAGpuHelper.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "GPU helper was not created: $executable" }
[pscustomobject]@{
    Status        = 'Built'
    Runtime       = $Runtime
    SelfContained = $SelfContained.IsPresent
    Executable    = $executable
    SizeBytes     = (Get-Item -LiteralPath $executable).Length
    Sha256        = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
}
