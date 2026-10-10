[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Security.Credentials.UI.UserConsentVerifier, Windows.Security.Credentials.UI, ContentType = WindowsRuntime]

function Wait-WinRtOperation {
    param(
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)][Type]$ResultType
    )

    $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.IsGenericMethodDefinition -and
            $_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1

    if ($null -eq $asTaskMethod) {
        throw 'Could not locate the WinRT AsTask adapter.'
    }

    $task = $asTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

$operation = [Windows.Security.Credentials.UI.UserConsentVerifier]::CheckAvailabilityAsync()
$availability = Wait-WinRtOperation `
    -Operation $operation `
    -ResultType ([Windows.Security.Credentials.UI.UserConsentVerifierAvailability])

$devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object { $_.PNPClass -in @('Biometric', 'Camera', 'Image') } |
    Select-Object PNPClass, Name, Status, DeviceID)

[pscustomobject]@{
    HelloAvailability = [string]$availability
    IsAvailable       = ([string]$availability -eq 'Available')
    WindowsBuild      = [Environment]::OSVersion.Version.Build
} | Format-List

Write-Host 'Relevant camera and biometric devices:' -ForegroundColor Cyan
if ($devices.Count -eq 0) {
    Write-Host 'No camera or biometric device was reported by Plug and Play.'
}
else {
    $devices | Format-Table -AutoSize
}

switch ([string]$availability) {
    'Available' {
        Write-Host 'Windows Hello verification is available for this user.' -ForegroundColor Green
    }
    'DeviceNotPresent' {
        Write-Warning 'Windows did not find a Windows Hello authentication device. A normal RGB webcam may not support Hello Face.'
    }
    'NotConfiguredForUser' {
        Write-Warning 'Compatible hardware may exist, but Windows Hello is not configured for this user.'
    }
    'DisabledByPolicy' {
        Write-Warning 'Windows Hello verification is disabled by policy.'
    }
    default {
        Write-Warning "Windows Hello is not currently available: $availability"
    }
}
