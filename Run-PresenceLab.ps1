[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Config = $null

function Write-RunState {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [hashtable]$Details = @{}
    )

    $state = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status       = $Status
        processId    = $PID
        details      = $Details
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ([string]$script:Config.StatePath) -Encoding UTF8
}

try {
    if (-not (Test-Path -LiteralPath $RunConfigPath -PathType Leaf)) {
        throw "Presence Lab run configuration was not found: $RunConfigPath"
    }
    $script:Config = Get-Content -Raw -LiteralPath $RunConfigPath | ConvertFrom-Json
    $persistent = (
        $null -ne $script:Config.PSObject.Properties['Persistent'] -and
        [bool]$script:Config.Persistent
    )
    if ($persistent) {
        $endUtc = $null
        $remainingHours = 0.0
    }
    else {
        $endUtc = [DateTimeOffset]::Parse([string]$script:Config.EndUtc).ToUniversalTime()
        $remaining = $endUtc - [DateTimeOffset]::UtcNow
        if ($remaining.TotalSeconds -le 0) {
            Write-RunState -Status 'completed' -Details @{ reason = 'end_time_reached_before_start' }
            exit 0
        }
        $remainingHours = [Math]::Max(0.01, $remaining.TotalHours)
    }

    $requiredPaths = @(
        [string]$script:Config.PythonPath,
        [string]$script:Config.FaceGuardPath,
        [string]$script:Config.ModelPath
    )
    if ([string]$script:Config.Engine -eq 'SFace') {
        $requiredPaths += [string]$script:Config.YuNetModelPath
        $requiredPaths += [string]$script:Config.SFaceModelPath
    }
    foreach ($path in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required Presence Lab component is missing: $path"
        }
    }

    Write-RunState -Status 'running' -Details @{
        startUtc       = [DateTime]::UtcNow.ToString('o')
        endUtc         = $(if ($null -eq $endUtc) { $null } else { $endUtc.ToString('o') })
        remainingHours = [Math]::Round($remainingHours, 4)
        engine          = [string]$script:Config.Engine
        persistent      = $persistent
        noLock         = $true
    }

    if ([string]$script:Config.Engine -eq 'SFace' -and [bool]$script:Config.Adaptive) {
        & ([string]$script:Config.PythonPath) ([string]$script:Config.FaceGuardPath) adaptive-test `
            --yunet-model ([string]$script:Config.YuNetModelPath) `
            --sface-model ([string]$script:Config.SFaceModelPath) `
            --model ([string]$script:Config.ModelPath) `
            --profile ([string]$script:Config.ProfilePath) `
            --log ([string]$script:Config.EventPath) `
            --camera-index ([int]$script:Config.CameraIndex) `
            --threshold ([double]$script:Config.Threshold) `
            --detection-threshold ([double]$script:Config.DetectionThreshold) `
            --baseline-seconds ([double]$script:Config.BaselineSeconds) `
            --cautious-seconds ([double]$script:Config.CautiousSeconds) `
            --warning-after-seconds ([double]$script:Config.WarningAfterSeconds) `
            --burst-interval-seconds ([double]$script:Config.BurstIntervalSeconds) `
            --burst-samples ([int]$script:Config.BurstSamples) `
            --recovery-matches ([int]$script:Config.RecoveryMatches) `
            --stable-margin ([double]$script:Config.StableMargin) `
            --opencv-threads ([int]$script:Config.OpenCvThreads) `
            --duration-hours $remainingHours `
            --start-minimized
    }
    elseif ([string]$script:Config.Engine -eq 'SFace') {
        & ([string]$script:Config.PythonPath) ([string]$script:Config.FaceGuardPath) presence-test `
            --yunet-model ([string]$script:Config.YuNetModelPath) `
            --sface-model ([string]$script:Config.SFaceModelPath) `
            --model ([string]$script:Config.ModelPath) `
            --profile ([string]$script:Config.ProfilePath) `
            --log ([string]$script:Config.EventPath) `
            --camera-index ([int]$script:Config.CameraIndex) `
            --threshold ([double]$script:Config.Threshold) `
            --detection-threshold ([double]$script:Config.DetectionThreshold) `
            --interval ([int]$script:Config.IntervalSeconds) `
            --scan-seconds ([int]$script:Config.ScanSeconds) `
            --duration-hours $remainingHours
    }
    else {
        & ([string]$script:Config.PythonPath) ([string]$script:Config.FaceGuardPath) presence-test `
            --model ([string]$script:Config.ModelPath) `
            --profile ([string]$script:Config.ProfilePath) `
            --log ([string]$script:Config.EventPath) `
            --camera-index ([int]$script:Config.CameraIndex) `
            --threshold ([double]$script:Config.Threshold) `
            --interval ([int]$script:Config.IntervalSeconds) `
            --scan-seconds ([int]$script:Config.ScanSeconds) `
            --duration-hours $remainingHours
    }

    $faceExitCode = $LASTEXITCODE
    if ($faceExitCode -eq 0) {
        Write-RunState -Status 'completed' -Details @{ exitCode = 0; noLock = $true }
        exit 0
    }

    Write-RunState -Status 'failed' -Details @{ exitCode = $faceExitCode; noLock = $true }
    exit $faceExitCode
}
catch {
    try {
        $message = "{0}`t{1}" -f [DateTime]::UtcNow.ToString('o'), $_.Exception.Message
        if ($null -ne $script:Config -and $null -ne $script:Config.PSObject.Properties['ErrorLogPath']) {
            Add-Content -LiteralPath ([string]$script:Config.ErrorLogPath) -Value $message -Encoding UTF8
            Write-RunState -Status 'failed' -Details @{ message = $_.Exception.Message; noLock = $true }
        }
    }
    catch {}
    exit 30
}
