[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'PowerCurve.Tests.ps1')
& (Join-Path $PSScriptRoot 'IdlePower.Tests.ps1')
& (Join-Path $PSScriptRoot 'OllamaAdapter.Tests.ps1')
& (Join-Path $PSScriptRoot 'LlamaBenchAdapter.Tests.ps1')
& (Join-Path $PSScriptRoot 'ComfyUIAdapter.Tests.ps1')
