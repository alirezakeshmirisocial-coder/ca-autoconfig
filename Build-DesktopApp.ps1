[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime = 'win-x64',

    [switch]$SelfContained
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectPath = Join-Path $PSScriptRoot 'src\CAAutoConfig.App\CAAutoConfig.App.csproj'
$localDotnet = Join-Path $PSScriptRoot '.tools\dotnet\dotnet.exe'
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnet = if ($null -ne $dotnetCommand) { $dotnetCommand.Source } elseif (Test-Path -LiteralPath $localDotnet -PathType Leaf) { $localDotnet } else { $null }
if ([string]::IsNullOrWhiteSpace($dotnet)) {
    throw 'The .NET 8 SDK was not found. Install it from https://dotnet.microsoft.com/download/dotnet/8.0 or into .tools\dotnet.'
}

$mode = if ($SelfContained) { 'self-contained' } else { 'framework-dependent' }
$outputPath = Join-Path $PSScriptRoot ("dist\desktop-{0}-{1}" -f $Runtime, $mode)
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
$publishExitCode = $LASTEXITCODE
if ($publishExitCode -ne 0) { throw "dotnet publish failed with exit code $publishExitCode." }

$executable = Join-Path $outputPath 'CAAutoConfig.exe'
$managedAssembly = Join-Path $outputPath 'CAAutoConfig.dll'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "Compiled application was not created: $executable"
}

[pscustomobject]@{
    Status        = 'Built'
    Framework     = 'net8.0-windows'
    Runtime       = $Runtime
    SelfContained = $SelfContained.IsPresent
    DotnetHost    = $dotnet
    DotnetRoot    = Split-Path -Parent $dotnet
    Executable    = $executable
    ManagedAssembly = $managedAssembly
    SizeBytes     = (Get-Item -LiteralPath $executable).Length
    Sha256        = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
}
