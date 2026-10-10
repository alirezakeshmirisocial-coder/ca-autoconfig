$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'tools\New-WindowsGpuLoadedValidationSummary.ps1'
$fixturePath = Join-Path $root 'benchmark\fixtures\dual-3090-280w.json'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('ca-loaded-validation-tests-' + [Guid]::NewGuid().ToString('N'))
$temporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($temporaryRoot) -notlike 'ca-loaded-validation-tests-*') {
    throw 'Unsafe temporary test path.'
}
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Json {
    param($Value, [string]$Path)
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Case {
    param($Windows, $Workload, [string]$Name)
    $windowsPath = Join-Path $temporaryRoot ($Name + '-windows.json')
    $workloadPath = Join-Path $temporaryRoot ($Name + '-workload.json')
    $outputPath = Join-Path $temporaryRoot ($Name + '-summary.json')
    Write-Json $Windows $windowsPath
    Write-Json $Workload $workloadPath
    $result = & $tool `
        -WindowsReportPath $windowsPath `
        -WorkloadRunPath $workloadPath `
        -OutputPath $outputPath `
        -MinimumLoadedUtilizationPercent 50 `
        -MinimumOverlapSeconds 3
    [pscustomobject]@{
        Result = $result
        Summary = Get-Content -Raw -LiteralPath $outputPath | ConvertFrom-Json
        Raw = Get-Content -Raw -LiteralPath $outputPath
        OutputPath = $outputPath
    }
}

try {
    $baseWorkload = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
    $baseWorkload.createdUtc = '2026-10-10T12:00:04Z'
    $baseWorkload.protocol.sampleSeconds = 4
    $baseWorkload.measurement | Add-Member -NotePropertyName startedUtc -NotePropertyValue '2026-10-10T12:00:00Z'
    $baseWorkload.measurement | Add-Member -NotePropertyName endedUtc -NotePropertyValue '2026-10-10T12:00:04Z'
    $baseWindows = [pscustomobject][ordered]@{
        schemaVersion = 3
        capturedUtc = '2026-10-10T12:00:10Z'
        source = 'live-windows-polling-read-only'
        counterProvider = 'windows-pdh-raw-engine'
        elapsedMilliseconds = 10000
        completedCollections = 5
        successfulMappingCollections = 5
        partialMappingCollections = 0
        unavailableCollections = 0
        suppressedOverlaps = 0
        successfulEngineLoadCollections = 5
        successfulDedicatedMemoryCollections = 5
        canUseInHud = $false
        hardwareWrites = $false
        networkAccess = $false
        elevationRequested = $false
        rawAdapterIdentifiersIncluded = $false
        failureReasonCounts = @()
    }

    $fixtureCase = Invoke-Case $baseWindows $baseWorkload 'fixture'
    Assert-True ($fixtureCase.Result.Status -eq 'FIXTURE_ONLY' -and
        -not [bool]$fixtureCase.Summary.promotionAuthorized) 'Fixture evidence advanced as live validation.'
    Write-Output 'PASS fixture evidence can exercise the linker but cannot advance'

    $liveWorkload = $baseWorkload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $liveWorkload.source = 'live'
    $readyCase = Invoke-Case $baseWindows $liveWorkload 'ready'
    Assert-True ($readyCase.Result.Status -eq 'READY_FOR_MANUAL_VALUE_COMPARISON' -and
        [double]$readyCase.Summary.overlap.coveragePercent -eq 100 -and
        [bool]$readyCase.Result.AllWorkloadGpusLoaded -and
        -not [bool]$readyCase.Summary.valuesCompared -and
        -not [bool]$readyCase.Summary.canUseInHud) 'Aligned loaded evidence received the wrong boundary.'
    Write-Output 'PASS aligned loaded evidence advances only to manual value comparison'

    $partialWindows = $baseWindows | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $partialWindows.successfulMappingCollections = 4
    $partialWindows.successfulEngineLoadCollections = 4
    $partialWindows.partialMappingCollections = 1
    $partialCase = Invoke-Case $partialWindows $liveWorkload 'partial'
    Assert-True ($partialCase.Result.Status -eq 'WINDOWS_PROVIDER_PARTIAL') 'A retained provider partial was hidden.'
    Write-Output 'PASS provider partials remain blocking evidence'

    $misalignedWorkload = $liveWorkload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $misalignedWorkload.measurement.startedUtc = '2026-10-10T13:00:00Z'
    $misalignedWorkload.measurement.endedUtc = '2026-10-10T13:00:04Z'
    $misalignedCase = Invoke-Case $baseWindows $misalignedWorkload 'misaligned'
    Assert-True ($misalignedCase.Result.Status -eq 'INSUFFICIENT_WINDOW_OVERLAP' -and
        [double]$misalignedCase.Summary.overlap.seconds -eq 0) 'Non-overlapping evidence was treated as simultaneous.'
    Write-Output 'PASS non-overlapping windows fail closed'

    $lowLoadWorkload = $liveWorkload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    foreach ($gpu in @($lowLoadWorkload.gpus)) {
        foreach ($sample in @($gpu.samples)) { $sample.utilizationPercent = 10 }
    }
    $lowLoadCase = Invoke-Case $baseWindows $lowLoadWorkload 'low-load'
    Assert-True ($lowLoadCase.Result.Status -eq 'WORKLOAD_NOT_FULLY_LOADED') 'Low utilization passed the loaded gate.'
    Write-Output 'PASS every workload GPU must meet the loaded threshold'

    $spikeWorkload = $liveWorkload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    foreach ($gpu in @($spikeWorkload.gpus)) {
        foreach ($sample in @($gpu.samples)) { $sample.utilizationPercent = 10 }
        $gpu.samples[0].utilizationPercent = 99
    }
    $spikeCase = Invoke-Case $baseWindows $spikeWorkload 'single-spike'
    Assert-True ($spikeCase.Result.Status -eq 'WORKLOAD_NOT_FULLY_LOADED' -and
        [double]$spikeCase.Summary.workloadWindow.gpuLoad[0].loadedSamplePercent -eq 25) 'A transient utilization spike passed as sustained load.'
    Write-Output 'PASS a transient utilization spike is not sustained load'

    $untimedWorkload = $liveWorkload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $untimedWorkload.measurement.PSObject.Properties.Remove('startedUtc')
    $untimedWorkload.measurement.PSObject.Properties.Remove('endedUtc')
    $untimedWorkloadPath = Join-Path $temporaryRoot 'untimed-workload.json'
    $untimedWindowsPath = Join-Path $temporaryRoot 'untimed-windows.json'
    $untimedOutput = Join-Path $temporaryRoot 'untimed-summary.json'
    Write-Json $untimedWorkload $untimedWorkloadPath
    Write-Json $baseWindows $untimedWindowsPath
    $threw = $false
    try {
        & $tool -WindowsReportPath $untimedWindowsPath -WorkloadRunPath $untimedWorkloadPath -OutputPath $untimedOutput | Out-Null
    }
    catch { $threw = $true }
    Assert-True ($threw -and -not (Test-Path -LiteralPath $untimedOutput)) 'An inferred workload window was accepted as explicit timing evidence.'
    $inconsistentWindowWorkload = $liveWorkload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $inconsistentWindowWorkload.measurement.endedUtc = '2026-10-10T12:00:30Z'
    $inconsistentWindowPath = Join-Path $temporaryRoot 'inconsistent-window-workload.json'
    $inconsistentWindowOutput = Join-Path $temporaryRoot 'inconsistent-window-summary.json'
    Write-Json $inconsistentWindowWorkload $inconsistentWindowPath
    $threw = $false
    try {
        & $tool -WindowsReportPath $untimedWindowsPath -WorkloadRunPath $inconsistentWindowPath -OutputPath $inconsistentWindowOutput | Out-Null
    }
    catch { $threw = $true }
    Assert-True ($threw -and -not (Test-Path -LiteralPath $inconsistentWindowOutput)) 'A workload window inconsistent with sampleSeconds was accepted.'
    Write-Output 'PASS explicit and internally consistent workload timestamps are required'

    Assert-True ($readyCase.Raw -notmatch 'Example 70B|fixture-dual-3090-280w-r1|ready-workload\.json|ready-windows\.json' -and
        -not [bool]$readyCase.Summary.privacy.inputFilenamesIncluded -and
        -not [bool]$readyCase.Summary.privacy.workloadIdentityIncluded) 'The linked summary exposed workload identity or filenames.'
    $privateWorkload = $liveWorkload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $privateWorkload.privacy.containsPaths = $true
    $privateOutput = Join-Path $temporaryRoot 'private-summary.json'
    $privateWorkloadPath = Join-Path $temporaryRoot 'private-workload.json'
    $privateWindowsPath = Join-Path $temporaryRoot 'private-windows.json'
    Write-Json $privateWorkload $privateWorkloadPath
    Write-Json $baseWindows $privateWindowsPath
    $threw = $false
    try {
        & $tool -WindowsReportPath $privateWindowsPath -WorkloadRunPath $privateWorkloadPath -OutputPath $privateOutput | Out-Null
    }
    catch { $threw = $true }
    Assert-True ($threw -and -not (Test-Path -LiteralPath $privateOutput)) 'Private workload evidence was accepted or written.'
    $unsafeWindows = $baseWindows | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $unsafeWindows.partialMappingCollections = 1
    $unsafeWindows.successfulMappingCollections = 4
    $unsafeWindows.successfulEngineLoadCollections = 4
    $unsafeWindows.failureReasonCounts = @([pscustomobject]@{ code = 'C:\Users\Private\counter'; count = 1 })
    $unsafeWindowsPath = Join-Path $temporaryRoot 'unsafe-reason-windows.json'
    $unsafeWorkloadPath = Join-Path $temporaryRoot 'unsafe-reason-workload.json'
    $unsafeOutput = Join-Path $temporaryRoot 'unsafe-reason-summary.json'
    Write-Json $unsafeWindows $unsafeWindowsPath
    Write-Json $liveWorkload $unsafeWorkloadPath
    $threw = $false
    try {
        & $tool -WindowsReportPath $unsafeWindowsPath -WorkloadRunPath $unsafeWorkloadPath -OutputPath $unsafeOutput | Out-Null
    }
    catch { $threw = $true }
    Assert-True ($threw -and -not (Test-Path -LiteralPath $unsafeOutput)) 'An unsafe Windows failure reason was accepted or copied.'
    Write-Output 'PASS linked summary omits identities and rejects private input'

    $invalidWindows = $baseWindows | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $invalidWindows.successfulMappingCollections = 5
    $invalidWindows.partialMappingCollections = 1
    $invalidWindowsPath = Join-Path $temporaryRoot 'invalid-counts-windows.json'
    $invalidWorkloadPath = Join-Path $temporaryRoot 'invalid-counts-workload.json'
    $invalidOutput = Join-Path $temporaryRoot 'invalid-counts-summary.json'
    Write-Json $invalidWindows $invalidWindowsPath
    Write-Json $liveWorkload $invalidWorkloadPath
    $threw = $false
    try {
        & $tool -WindowsReportPath $invalidWindowsPath -WorkloadRunPath $invalidWorkloadPath -OutputPath $invalidOutput | Out-Null
    }
    catch { $threw = $true }
    Assert-True ($threw -and -not (Test-Path -LiteralPath $invalidOutput)) 'Inconsistent Windows collection counts were accepted.'
    Write-Output 'PASS inconsistent Windows collection counts fail closed'

    $collisionWindowsPath = Join-Path $temporaryRoot 'collision-windows.json'
    $collisionWorkloadPath = Join-Path $temporaryRoot 'collision-workload.json'
    Write-Json $baseWindows $collisionWindowsPath
    Write-Json $liveWorkload $collisionWorkloadPath
    $windowsBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $collisionWindowsPath).Hash
    $threw = $false
    try {
        & $tool `
            -WindowsReportPath $collisionWindowsPath `
            -WorkloadRunPath $collisionWorkloadPath `
            -OutputPath $collisionWindowsPath `
            -Force | Out-Null
    }
    catch { $threw = $true }
    $windowsAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $collisionWindowsPath).Hash
    Assert-True ($threw -and $windowsBefore -eq $windowsAfter) 'An output/input collision was accepted or changed the input.'
    $replacementOutput = Join-Path $temporaryRoot 'force-replacement-summary.json'
    Set-Content -LiteralPath $replacementOutput -Value 'old-output' -Encoding UTF8
    $replacementResult = & $tool `
        -WindowsReportPath $collisionWindowsPath `
        -WorkloadRunPath $collisionWorkloadPath `
        -OutputPath $replacementOutput `
        -MinimumLoadedUtilizationPercent 50 `
        -MinimumLoadedSamplePercent 50 `
        -MinimumOverlapSeconds 3 `
        -Force
    $replacementSummary = Get-Content -Raw -LiteralPath $replacementOutput | ConvertFrom-Json
    $orphanedTemporaryFiles = @(Get-ChildItem -LiteralPath $temporaryRoot -Filter '.ca-loaded-validation-*.tmp')
    Assert-True ([string]$replacementResult.Status -eq 'READY_FOR_MANUAL_VALUE_COMPARISON' -and
        [string]$replacementSummary.status -eq 'READY_FOR_MANUAL_VALUE_COMPARISON' -and
        $orphanedTemporaryFiles.Count -eq 0) 'A forced summary replacement was incomplete or left a temporary file.'
    Write-Output 'PASS output cannot overwrite inputs and forced replacement is complete'

    Write-Output '10 Windows GPU loaded-validation tests passed. Fixtures performed no network or hardware access.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $temporaryRoot).Path)
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notlike 'ca-loaded-validation-tests-*') {
            throw 'Refusing unsafe temporary test cleanup.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
