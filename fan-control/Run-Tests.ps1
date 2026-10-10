[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Run in a fresh PowerShell process after editing: Add-Type types live for the process lifetime.
# This runner compiles in memory. It never loads NVML or runs GPU utilities.
Add-Type -Path @(
    (Join-Path $PSScriptRoot 'AdaptiveFanPolicy.cs'),
    (Join-Path $PSScriptRoot 'PredictiveThermalModel.cs'),
    (Join-Path $PSScriptRoot 'AdaptiveFanPolicy.Tests.cs'),
    (Join-Path $PSScriptRoot 'PredictiveThermalModel.Tests.cs')
)
$results = @([CA.FanControlTests.PolicyTests]::RunAll()) + @([CA.FanControlTests.PredictiveTests]::RunAll())
$results | ForEach-Object { Write-Output $_ }
Write-Output ("{0} isolated policy tests passed. No GPU settings were read or changed." -f $results.Count)
