[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$planScript = Join-Path $root 'Get-GpuLimitPlan.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures\gpu-limit-plan.csv'
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

function Invoke-FixturePlan {
    param([hashtable]$Extra = @{})
    $parameters = @{
        GpuIndexList = '0,1'
        FixtureCsvPath = $fixture
        SkipMigrationInspection = $true
    }
    foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
    & $planScript @parameters
}

Test-Case 'inventory computes a shared no-raise starting point' {
    $plan = Invoke-FixturePlan
    Assert-True ($plan.PlanStatus -eq 'INVENTORY' -and -not $plan.CanProceedToInstaller) 'Inventory unexpectedly authorized installation.'
    Assert-True ([double]$plan.SuggestedSharedPowerStartingPointWatts -eq 280) 'Shared starting point did not respect the lower current/default-derived cap.'
    Assert-True ($null -eq $plan.SuggestedClockMHz) 'Inventory fabricated a workload-independent clock suggestion.'
    Assert-True (-not $plan.HardwareWrites -and $plan.SelectedGpuCount -eq 2) 'Inventory safety metadata is wrong.'
}

Test-Case 'safe fixture profile passes checks but cannot authorize installation' {
    $plan = Invoke-FixturePlan @{ PowerLimitWatts = 280; MaxGraphicsClockMHz = 1700 }
    Assert-True ($plan.PlanStatus -eq 'FIXTURE' -and $plan.WouldPassSafetyChecks) 'Safe fixture profile did not exercise the ready path.'
    Assert-True ($plan.ProfileChecksPass -and $plan.MigrationChecksPass) 'Independent profile/migration checks are wrong.'
    Assert-True (-not $plan.CanProceedToInstaller -and @($plan.ReasonCodes) -contains 'fixture-source') 'Fixture plan authorized installation.'
}

Test-Case 'power outside one board range is rejected' {
    $plan = Invoke-FixturePlan @{ PowerLimitWatts = 400; MaxGraphicsClockMHz = 1700; AcknowledgePowerIncrease = $true }
    Assert-True ($plan.PlanStatus -eq 'REJECTED' -and @($plan.ReasonCodes) -contains 'outside-vendor-power-range') 'Board-specific range violation was not rejected.'
}

Test-Case 'vendor maximum clock is enforced before installation' {
    $plan = Invoke-FixturePlan @{ PowerLimitWatts = 280; MaxGraphicsClockMHz = 2200 }
    Assert-True ($plan.PlanStatus -eq 'REJECTED' -and @($plan.ReasonCodes) -contains 'above-vendor-maximum-clock') 'Vendor clock maximum violation was not rejected.'
}

Test-Case 'raising a current cap needs a separate acknowledgement' {
    $blocked = Invoke-FixturePlan @{ PowerLimitWatts = 300; MaxGraphicsClockMHz = 1700 }
    Assert-True ($blocked.PlanStatus -eq 'REJECTED' -and @($blocked.ReasonCodes) -contains 'would-raise-current-power-limit') 'Power increase advanced without acknowledgement.'
    $acknowledged = Invoke-FixturePlan @{ PowerLimitWatts = 300; MaxGraphicsClockMHz = 1700; AcknowledgePowerIncrease = $true }
    Assert-True ($acknowledged.PlanStatus -eq 'FIXTURE' -and $acknowledged.WouldRaiseCurrentPowerLimit) 'Acknowledged power increase did not remain visible.'
}

Test-Case 'partial proposed profile is rejected' {
    $plan = Invoke-FixturePlan @{ PowerLimitWatts = 280 }
    Assert-True ($plan.PlanStatus -eq 'REJECTED' -and @($plan.ReasonCodes) -contains 'incomplete-proposed-profile') 'Partial profile was not rejected.'
}

Test-Case 'plan source contains no NVIDIA mutation operation' {
    $source = Get-Content -Raw -LiteralPath $planScript
    Assert-True ($source -notmatch "'-pl'" -and $source -notmatch "'-lgc'" -and $source -notmatch "'-rgc'") 'Read-only plan contains an NVIDIA mutation flag.'
    Assert-True ($source -notmatch 'Start-Process' -and $source -notmatch '-Verb RunAs') 'Read-only plan contains process elevation.'
}

Write-Host "$passed GPU limit plan tests passed. No GPU settings were read or changed by the fixture suite." -ForegroundColor Cyan
