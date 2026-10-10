$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $root 'Invoke-RepositoryChecks.ps1'
$source = Get-Content -LiteralPath $runner -Raw

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$full = @(& $runner -Suite Full -ListOnly)
$powerShell = @(& $runner -Suite PowerShell -ListOnly)

Assert-True ($full.Count -eq 17) 'Full suite does not contain exactly 17 named checks.'
Assert-True ($powerShell.Count -eq 14) 'PowerShell suite does not contain exactly 14 named checks.'
Assert-True (@($full | Where-Object { $_.Kind -eq 'DotNetProject' }).Count -eq 1) 'Full suite does not contain the compiled telemetry project.'
Assert-True (@($powerShell | Where-Object { $_.FullOnly }).Count -eq 0) 'PowerShell suite included a Full-only check.'
Assert-True (@($full | Where-Object { $_.Name -eq 'Compiled desktop smoke' }).Count -eq 1) 'Full suite omitted the compiled desktop smoke test.'
Assert-True (@($full | Where-Object { $_.Name -eq 'Privileged helper safety' }).Count -eq 1) 'Full suite omitted the privileged helper safety test.'
Assert-True (@($powerShell | Where-Object { $_.Name -eq 'Display diagnostics preflight' }).Count -eq 1) 'PowerShell suite omitted the display preflight.'
Assert-True (@($powerShell | Where-Object { $_.Name -eq 'Repository-check orchestration' }).Count -eq 1) 'PowerShell suite omitted its orchestration policy test.'

foreach ($step in $full) {
    Assert-True (Test-Path -LiteralPath (Join-Path $root $step.RelativePath) -PathType Leaf) "Missing check input: $($step.RelativePath)"
}

foreach ($requiredBoundary in @(
    "CompleteRepositoryValidation = `$completeRepositoryValidation",
    "PASSED_POWERSHELL_SUITE_ONLY",
    "HardwareWrites = `$false",
    "GpuSettingsChanged = `$false",
    "SleepInitiated = `$false",
    "ExternalPostsCreated = `$false",
    "refusing to overwrite prior evidence"
)) {
    Assert-True $source.Contains($requiredBoundary) "Runner omitted safety boundary: $requiredBoundary"
}

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($runner, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'Repository-check runner does not parse.'
$commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
foreach ($forbidden in @('Invoke-Expression', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer', 'Start-Process', 'Set-ItemProperty')) {
    Assert-True ($commands -notcontains $forbidden) "Runner contains forbidden command: $forbidden"
}
Assert-True ($source -notmatch '(?i)nvidia-smi.+(?:-pl|-lgc|-rgc)') 'Runner contains a direct GPU mutation command.'

Write-Host '9 repository-check orchestration tests passed. ListOnly performed no child test, network, hardware, or GPU-setting access.' -ForegroundColor Cyan
