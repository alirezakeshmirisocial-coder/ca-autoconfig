[CmdletBinding()]
param(
    [string]$FixtureJsonPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = if ([string]::IsNullOrWhiteSpace($FixtureJsonPath)) { 'live' } else { 'fixture' }
$counterStatus = 'unavailable'
$counterSetNames = @()
$controllers = @()

function Assert-AllowedProperties {
    param([object]$Object, [string[]]$Allowed, [string]$Label)
    foreach ($property in @($Object.PSObject.Properties.Name)) {
        if ($property -notin $Allowed) { throw "Fixture contains unsupported $Label property '$property'." }
    }
}

if ($source -eq 'fixture') {
    if (-not (Test-Path -LiteralPath $FixtureJsonPath -PathType Leaf)) { throw "Fixture JSON is missing: $FixtureJsonPath" }
    $fixture = Get-Content -Raw -LiteralPath $FixtureJsonPath | ConvertFrom-Json
    Assert-AllowedProperties $fixture @('schemaVersion', 'counterStatus', 'counterSetNames', 'controllers') 'top-level'
    if ([int]$fixture.schemaVersion -ne 1) { throw 'Unsupported capability fixture schema.' }
    $counterStatus = [string]$fixture.counterStatus
    if ($counterStatus -notin @('available', 'unavailable', 'access-denied', 'error', 'command-unavailable')) { throw 'Invalid fixture counter status.' }
    $counterSetNames = @($fixture.counterSetNames | ForEach-Object { [string]$_ })
    foreach ($controller in @($fixture.controllers)) {
        Assert-AllowedProperties $controller @('name', 'driverVersion') 'controller'
        $name = ([string]$controller.name).Trim()
        $driver = ([string]$controller.driverVersion).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'Fixture controller name is empty.' }
        $controllers += [pscustomobject][ordered]@{ Name = $name; DriverVersion = $driver }
    }
}
else {
    try {
        $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object {
            $name = ([string]$_.Name).Trim()
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                [pscustomobject][ordered]@{ Name = $name; DriverVersion = ([string]$_.DriverVersion).Trim() }
            }
        })
    }
    catch { $controllers = @() }

    $counterCommand = Get-Command Get-Counter -ErrorAction SilentlyContinue
    if ($null -eq $counterCommand) {
        $counterStatus = 'command-unavailable'
    }
    else {
        try {
            $sets = @(Get-Counter -ListSet 'GPU*' -ErrorAction Stop)
            $counterSetNames = @($sets | ForEach-Object { [string]$_.CounterSetName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
            $counterStatus = if ($counterSetNames.Count -gt 0) { 'available' } else { 'unavailable' }
        }
        catch {
            $message = [string]$_.Exception.Message
            $counterStatus = if ($_.Exception -is [UnauthorizedAccessException] -or $message -match 'Performance Log Users|access.*denied') { 'access-denied' } else { 'error' }
        }
    }
}

$capabilityReasons = New-Object Collections.Generic.List[string]
if ($controllers.Count -eq 0) { $capabilityReasons.Add('no-video-controllers') }
if ($counterStatus -ne 'available') { $capabilityReasons.Add('gpu-counter-set-' + $counterStatus) }
$hasEngineCounters = @($counterSetNames | Where-Object { $_ -match 'GPU.*Engine|Engine.*GPU' }).Count -gt 0
$hasMemoryCounters = @($counterSetNames | Where-Object { $_ -match 'GPU.*Memory|Memory.*GPU' }).Count -gt 0
if ($counterStatus -eq 'available' -and -not $hasEngineCounters) { $capabilityReasons.Add('gpu-engine-counter-missing') }
if ($counterStatus -eq 'available' -and -not $hasMemoryCounters) { $capabilityReasons.Add('gpu-memory-counter-missing') }

$capabilityReasonCodes = @($capabilityReasons | Select-Object -Unique)
$checksPass = $capabilityReasonCodes.Count -eq 0
$reasonCodes = @($capabilityReasonCodes)
if ($source -eq 'fixture') { $reasonCodes = @('fixture-source') + $reasonCodes }
$reasonCodes += 'adapter-mapping-unvalidated'

[pscustomobject][ordered]@{
    SchemaVersion = 1
    CapturedUtc = [DateTime]::UtcNow.ToString('o')
    Source = $source
    ProbeStatus = if (-not $checksPass) { 'BLOCKED' } elseif ($source -eq 'fixture') { 'FIXTURE' } else { 'CAPABILITY_AVAILABLE' }
    CounterStatus = $counterStatus
    CounterSetCount = $counterSetNames.Count
    HasGpuEngineCounters = $hasEngineCounters
    HasGpuMemoryCounters = $hasMemoryCounters
    ControllerCount = $controllers.Count
    Controllers = @($controllers)
    CapabilityChecksPass = $checksPass
    CanProceedToMappingValidation = $source -eq 'live' -and $checksPass
    CanUseInHud = $false
    ReasonCodes = @($reasonCodes | Select-Object -Unique)
    HardwareWrites = $false
    NetworkAccess = $false
    ElevationRequested = $false
    RawAdapterIdentifiersIncluded = $false
}
