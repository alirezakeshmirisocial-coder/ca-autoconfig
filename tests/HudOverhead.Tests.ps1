$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'tools\Measure-HudOverhead.ps1'
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ca-hud-overhead-tests-' + [Guid]::NewGuid().ToString('N'))))
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($temporaryRoot) -notlike 'ca-hud-overhead-tests-*') { throw 'Unsafe temporary test path.' }
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Write-Json { param($Value, [string]$Name); $path = Join-Path $temporaryRoot $Name; [IO.File]::WriteAllText($path, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false))); return $path }
function Assert-Rejected { param([scriptblock]$Action, [string]$Message); $rejected = $false; try { & $Action | Out-Null } catch { $rejected = $_.Exception.Message -like 'HUD overhead measurement failed:*' }; Assert-True $rejected $Message }
function Test-Case { param([string]$Name, [scriptblock]$Body); & $Body; Write-Host "PASS $Name" -ForegroundColor Green; $script:passed++ }

$samples = @(
    @{ elapsedSeconds = 0.0; cpuSeconds = 10.00; workingSetBytes = 64MB; privateBytes = 24MB; responding = $true },
    @{ elapsedSeconds = 2.0; cpuSeconds = 10.16; workingSetBytes = 66MB; privateBytes = 25MB; responding = $true },
    @{ elapsedSeconds = 4.0; cpuSeconds = 10.32; workingSetBytes = 68MB; privateBytes = 26MB; responding = $true },
    @{ elapsedSeconds = 6.0; cpuSeconds = 10.56; workingSetBytes = 70MB; privateBytes = 27MB; responding = $false }
)
$fixture = @{ schemaVersion = 1; processorCount = 8; samples = $samples }
$passed = 0

try {
    Test-Case 'fixture computes normalized CPU and memory exactly' {
        $result = & $tool -FixturePath (Write-Json $fixture 'valid.json')
        Assert-True ($result.Status -eq 'FIXTURE_NOT_HARDWARE_EVIDENCE' -and -not $result.MeasuredLive) 'Fixture was promoted to live evidence.'
        Assert-True ([Math]::Abs($result.Cpu.Mean - 1.1667) -lt 0.0001) 'Normalized CPU mean is wrong.'
        Assert-True ($result.Cpu.P95 -eq 1.5 -and $result.WorkingSetMiB.Maximum -eq 70) 'Percentile or memory summary is wrong.'
    }
    Test-Case 'non-responding samples remain visible' {
        $result = & $tool -FixturePath (Join-Path $temporaryRoot 'valid.json')
        Assert-True ($result.NonRespondingSampleCount -eq 1 -and -not $result.Samples[-1].Responding) 'Non-responding evidence was hidden.'
    }
    Test-Case 'output omits process and machine identity' {
        $result = & $tool -FixturePath (Join-Path $temporaryRoot 'valid.json')
        $json = $result | ConvertTo-Json -Depth 8
        Assert-True ($json -notmatch '(?i)"processId"\s*:|"executablePath"\s*:\s*"[A-Z]:|"machineName"\s*:|"userName"\s*:') 'Identity or path was exported.'
        Assert-True (-not $result.Boundaries.ProcessIdExported -and -not $result.Boundaries.ExecutablePathExported -and -not $result.Boundaries.MachineOrUserIdentityExported) 'Privacy boundary is wrong.'
    }
    Test-Case 'decreasing cumulative CPU is rejected' {
        $bad = $fixture | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.samples[2].cpuSeconds = 9.0
        Assert-Rejected { & $tool -FixturePath (Write-Json $bad 'decreasing.json') } 'Decreasing CPU evidence was accepted.'
    }
    Test-Case 'non-monotonic time is rejected' {
        $bad = $fixture | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.samples[2].elapsedSeconds = 2.0
        Assert-Rejected { & $tool -FixturePath (Write-Json $bad 'time.json') } 'Non-monotonic time was accepted.'
    }
    Test-Case 'unsupported private fixture fields are rejected' {
        $bad = $fixture | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad | Add-Member -NotePropertyName machineName -NotePropertyValue 'private-host'
        Assert-Rejected { & $tool -FixturePath (Write-Json $bad 'private.json') } 'Private fixture field was accepted.'
    }
    Test-Case 'result file is written once and never overwrites evidence' {
        $output = Join-Path $temporaryRoot 'summary.json'
        & $tool -FixturePath (Join-Path $temporaryRoot 'valid.json') -ResultPath $output | Out-Null
        $saved = Get-Content -LiteralPath $output -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($saved.Status -eq 'FIXTURE_NOT_HARDWARE_EVIDENCE') 'Saved evidence changed grade.'
        Assert-Rejected { & $tool -FixturePath (Join-Path $temporaryRoot 'valid.json') -ResultPath $output } 'Existing evidence was overwritten.'
    }
    Test-Case 'result cannot overwrite its fixture input' {
        $path = Join-Path $temporaryRoot 'valid.json'
        Assert-Rejected { & $tool -FixturePath $path -ResultPath $path } 'Fixture input was overwritten.'
    }
    Test-Case 'live source has no network, process-control, or GPU mutation command' {
        $source = Get-Content -LiteralPath $tool -Raw
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($tool, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) 'Tool does not parse.'
        $commands = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]}, $true) | ForEach-Object {$_.GetCommandName()} | Where-Object {$_})
        foreach ($forbidden in @('Invoke-WebRequest','Invoke-RestMethod','Start-Process','Stop-Process','Remove-Item','Set-ItemProperty','schtasks.exe','nvidia-smi')) { Assert-True ($commands -notcontains $forbidden) "Forbidden command found: $forbidden" }
        Assert-True ($source -notmatch '(?i)(?:-pl|-lgc|-rgc)') 'GPU mutation flag found.'
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host "$passed HUD-overhead tests passed. Fixtures performed no live process, network, hardware, or GPU-setting access." -ForegroundColor Cyan
