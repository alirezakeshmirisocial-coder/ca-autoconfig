$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$harnessPath = Join-Path $root 'tools\Invoke-WindowsGpuChurnValidation.ps1'
$fixturePath = Join-Path $PSScriptRoot 'fixtures\windows-gpu-churn.html'
$harness = Get-Content -Raw -LiteralPath $harnessPath
$fixture = Get-Content -Raw -LiteralPath $fixturePath

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $harnessPath,
    [ref]$tokens,
    [ref]$errors)
Assert-True ($errors.Count -eq 0) 'The churn harness has PowerShell parse errors.'
Write-Output 'PASS churn harness parses as PowerShell'

$nvidiaCommands = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'nvidia-smi'
}, $true))
Assert-True ($nvidiaCommands.Count -eq 1) 'Expected exactly one NVIDIA query command.'
$nvidiaText = $nvidiaCommands[0].Extent.Text
Assert-True ($nvidiaText -match '--query-gpu=utilization\.gpu') 'NVIDIA corroboration is not query-only.'
Assert-True ($nvidiaText -notmatch '(?i)(?:^|\s)(?:-pl|--power-limit|-lgc|--lock-gpu-clocks|--reset-gpu-clocks)(?:\s|$)') 'A GPU mutation flag entered the churn harness.'
Write-Output 'PASS NVIDIA corroboration is query-only'

Assert-True ($harness -match "--windows-gpu-provider', 'pdh-raw'") 'The harness is not pinned to the explicit raw provider.'
Assert-True ($harness -match "'--disable-background-networking'") 'The isolated browser does not disable background networking.'
Assert-True ($harness -match 'fixtureUsesLocalFileOnly\s*=\s*\$true') 'The summary does not declare its local-file boundary.'
Assert-True ($harness -notmatch 'pollingReportFile\s*=') 'The summary can expose a user-selected report filename.'
Write-Output 'PASS harness pins raw PDH and a local browser fixture'

Assert-True ($harness -match 'StartsWith\(\$tempRoot') 'Temporary-profile cleanup is not rooted under the system temp directory.'
Assert-True ($harness -match 'GetFileName\(\$resolvedProfile\).*ca-gpu-churn-') 'Temporary-profile cleanup lacks the dedicated prefix guard.'
Assert-True ($harness -match 'CommandLine\.IndexOf\(\$profilePath') 'Browser cleanup is not scoped to the unique profile token.'
Write-Output 'PASS process cleanup is scoped to the guarded temporary profile'

Assert-True ($fixture -match 'getContext\("webgl"') 'The fixture does not request WebGL.'
Assert-True ($fixture -match 'requestAnimationFrame') 'The fixture does not sustain a render loop.'
Assert-True ($fixture -notmatch '(?i)https?://|fetch\s*\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon') 'The local fixture contains a network-capable endpoint or API.'
Write-Output 'PASS WebGL fixture has no network endpoint or client API'

Write-Output '5 Windows GPU churn-harness tests passed. No browser was launched and no GPU setting was read or changed.'
