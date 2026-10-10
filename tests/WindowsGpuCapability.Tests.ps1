[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$probe = Join-Path $root 'Get-WindowsGpuCapability.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures\windows-gpu-capability.json'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('ca-windows-gpu-capability-' + [Guid]::NewGuid().ToString('N'))
$passed = 0

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

function Write-Fixture {
    param([string]$Name, [object]$Value)
    $path = Join-Path $temporaryRoot ($Name + '.json')
    $Value | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

    Test-Case 'complete fixture proves capability but cannot authorize HUD use' {
        $result = & $probe -FixtureJsonPath $fixture
        Assert-True ($result.ProbeStatus -eq 'FIXTURE' -and $result.CapabilityChecksPass) 'Complete fixture did not exercise the capability path.'
        Assert-True (-not $result.CanProceedToMappingValidation -and -not $result.CanUseInHud) 'Fixture authorized live progression or HUD use.'
        Assert-True (@($result.ReasonCodes) -contains 'fixture-source' -and @($result.ReasonCodes) -contains 'adapter-mapping-unvalidated') 'Fixture boundaries are missing.'
    }

    Test-Case 'unavailable counters fail closed' {
        $path = Write-Fixture 'unavailable' ([ordered]@{ schemaVersion = 1; counterStatus = 'access-denied'; counterSetNames = @(); controllers = @([ordered]@{ name = 'GPU'; driverVersion = '1' }) })
        $result = & $probe -FixtureJsonPath $path
        Assert-True ($result.ProbeStatus -eq 'BLOCKED' -and @($result.ReasonCodes) -contains 'gpu-counter-set-access-denied') 'Access-denied counters did not fail closed.'
    }

    Test-Case 'missing engine or memory set is explicit' {
        $path = Write-Fixture 'partial' ([ordered]@{ schemaVersion = 1; counterStatus = 'available'; counterSetNames = @('GPU Engine'); controllers = @([ordered]@{ name = 'GPU'; driverVersion = '1' }) })
        $result = & $probe -FixtureJsonPath $path
        Assert-True (@($result.ReasonCodes) -contains 'gpu-memory-counter-missing' -and -not $result.CapabilityChecksPass) 'Partial counter capability was promoted.'
    }

    Test-Case 'missing controller inventory fails closed' {
        $path = Write-Fixture 'no-controller' ([ordered]@{ schemaVersion = 1; counterStatus = 'available'; counterSetNames = @('GPU Engine', 'GPU Adapter Memory'); controllers = @() })
        $result = & $probe -FixtureJsonPath $path
        Assert-True (@($result.ReasonCodes) -contains 'no-video-controllers') 'Missing controller inventory was not rejected.'
    }

    Test-Case 'raw identifier fields are rejected from fixtures' {
        $path = Write-Fixture 'raw-id' ([ordered]@{ schemaVersion = 1; counterStatus = 'available'; counterSetNames = @('GPU Engine', 'GPU Adapter Memory'); controllers = @([ordered]@{ name = 'GPU'; driverVersion = '1'; pnpDeviceId = 'private' }) })
        try { & $probe -FixtureJsonPath $path | Out-Null; throw 'Expected raw-identifier rejection did not occur.' }
        catch { Assert-True ($_.Exception.Message -match 'unsupported controller property') "Unexpected fixture rejection: $($_.Exception.Message)" }
    }

    Test-Case 'reported controller fields remain privacy scoped' {
        $result = & $probe -FixtureJsonPath $fixture
        foreach ($controller in @($result.Controllers)) {
            Assert-True ((@($controller.PSObject.Properties.Name) -join ',') -eq 'Name,DriverVersion') 'Controller output exposed an unapproved field.'
        }
        Assert-True (-not $result.RawAdapterIdentifiersIncluded -and -not $result.HardwareWrites -and -not $result.NetworkAccess -and -not $result.ElevationRequested) 'Probe safety metadata is wrong.'
    }

    Test-Case 'probe source is query-only and non-elevating' {
        $source = Get-Content -Raw -LiteralPath $probe
        Assert-True ($source -match 'Get-Counter' -and $source -match 'Get-CimInstance') 'Expected Windows capability queries are missing.'
        Assert-True ($source -notmatch 'Start-Process|Invoke-WebRequest|Invoke-RestMethod|Add-LocalGroupMember|Set-Acl|nvidia-smi|''-pl''|''-lgc''|''-rgc''') 'Probe source contains elevation, network, ACL, membership, or GPU mutation behavior.'
    }

    Write-Host "$passed Windows GPU capability tests passed. Fixture tests did not query hardware." -ForegroundColor Cyan
}
finally {
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved -PathType Container)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
