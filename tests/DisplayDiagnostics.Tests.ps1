$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'tools\Test-DisplayDiagnostics.ps1'
$form = Join-Path $root '.github\ISSUE_TEMPLATE\display-result.yml'
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ca-display-diagnostics-tests-' + [Guid]::NewGuid().ToString('N'))))
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($temporaryRoot) -notlike 'ca-display-diagnostics-tests-*') {
    throw 'Unsafe temporary test path.'
}
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    Write-Host "PASS $Name" -ForegroundColor Green
    $script:passed++
}

function Write-Fixture {
    param([string]$Name, [string]$Content)
    $path = Join-Path $temporaryRoot $Name
    [IO.File]::WriteAllText($path, $Content, (New-Object Text.UTF8Encoding($false)))
    return $path
}

function Assert-Rejected {
    param([string]$Name, [string]$Content)
    $rejected = $false
    try { & $tool -Path (Write-Fixture $Name $Content) | Out-Null }
    catch { $rejected = $_.Exception.Message -like 'Display diagnostics preflight failed:*' }
    Assert-True $rejected "Fixture $Name was not rejected."
}

$valid = @'
CA AutoConfig diagnostics (privacy-safe)
App: 0.2.6-alpha.4
Captured UTC: 2026-10-10T12:00:00Z
Windows: Microsoft Windows NT 10.0.19045.0 · X64
Shortcut: Ctrl + Alt + L
Selected display: Display 3 · 1920x1080
GPU profile: ACTIVE 1700 MHz / 280 W

Displays:
- Display 1: 3840x2160 at (0,0); 200%; primary
- Display 2: 1920x1080 at (-1920,0); 100%
- Display 3: 1920x1080 at (0,2160); 125%; selected
GPUs:
- GPU 0: RTX 3090; CUDA/SM 22%; VRAM 40%; power 140/280 W (default 350 W); vendor range 100-370 W; temperature 52 C; clock 1695 MHz; 260 W starting point
Privacy: excludes usernames, machine names, GPU UUIDs, paths, prompts, outputs, workflows, and image content.
'@

$passed = 0
try {
    $formText = Get-Content -LiteralPath $form -Raw -Encoding UTF8
    foreach ($requiredFormText in @(
        'Test-DisplayDiagnostics.ps1',
        'Monitor-map selection:',
        'Tiny lock/unlock control:',
        'Global shortcut:',
        'Locked click-through:',
        'Restart persistence:',
        'Session-unlock persistence:',
        'No clipping or taskbar overlap:',
        'I reported failed and untested checks instead of claiming they passed.',
        'A star is not requested or required.'
    )) {
        Assert-True $formText.Contains($requiredFormText) "Display result form omitted: $requiredFormText"
    }
    Test-Case 'valid mixed-DPI negative-coordinate report is attachable' {
        $result = & $tool -Path (Write-Fixture 'valid.txt' $valid)
        Assert-True $result.SafeToAttach 'Valid report was not attachable.'
        Assert-True ($result.DisplayCount -eq 3 -and $result.SelectedDisplayIndex -eq 3) 'Display summary was wrong.'
        Assert-True ($result.HasMixedDpi -and $result.HasNegativeCoordinates -and $result.HasVerticalOffset) 'Topology signals were not preserved.'
        Assert-True (-not $result.ContentEchoed -and -not $result.NetworkAccess -and -not $result.FilesModified -and -not $result.HardwareAccess) 'Preflight safety boundary changed.'
    }
    Test-Case 'report without a GPU remains valid display evidence' {
        $noGpu = [Regex]::Replace($valid, '(?m)^- GPU 0:.*$', '- None reported')
        $result = & $tool -Path (Write-Fixture 'no-gpu.txt' $noGpu)
        Assert-True ($result.SafeToAttach -and $result.GpuSummaryCount -eq 0) 'A display-only report was not accepted.'
    }
    Test-Case 'missing privacy boundary is rejected' {
        Assert-Rejected 'missing-privacy.txt' ($valid -replace '(?m)^Privacy:.*$', '')
    }
    Test-Case 'GPU UUID is rejected' {
        Assert-Rejected 'uuid.txt' ($valid -replace 'RTX 3090', 'RTX 3090 GPU-00000000-0000-0000-0000-000000000000')
    }
    Test-Case 'local path is rejected' {
        Assert-Rejected 'path.txt' ($valid -replace 'ACTIVE 1700 MHz / 280 W', 'C:\Users\Alice\profile.json')
    }
    Test-Case 'raw Windows device name is rejected' {
        Assert-Rejected 'device.txt' ($valid -replace 'Display 3 · 1920x1080', '\\.\DISPLAY7')
    }
    Test-Case 'unexpected identity field is rejected' {
        Assert-Rejected 'identity.txt' ($valid -replace 'Shortcut:', 'Machine: workstation`nShortcut:')
    }
    Test-Case 'multiple primary displays are rejected' {
        Assert-Rejected 'primary.txt' ($valid -replace '(?m)^- Display 2: 1920x1080 at \(-1920,0\); 100%$', '- Display 2: 1920x1080 at (-1920,0); 100%; primary')
    }
    Test-Case 'selected summary must match topology' {
        Assert-Rejected 'selected.txt' ($valid -replace 'Selected display: Display 3', 'Selected display: Display 2')
        Assert-Rejected 'selected-resolution.txt' ($valid -replace 'Selected display: Display 3 · 1920x1080', 'Selected display: Display 3 · 2560x1440')
        Assert-Rejected 'duplicate-selected.txt' ($valid -replace '125%; selected', '125%; selected; selected')
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host "$passed display diagnostics preflight tests passed. Fixtures performed no network, hardware, or GPU-setting access." -ForegroundColor Cyan
