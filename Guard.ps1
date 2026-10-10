[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$DesktopPathOverride,
    [string]$DataPathOverride,
    [int]$TimeoutSecondsOverride = 0,
    [switch]$NoLock,
    [switch]$NoUi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ExitCode = 0
$script:Mutex = $null
$script:HasMutex = $false

function Get-DefaultDataPath {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CAUnlockGuard'
}

function Write-GuardEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [hashtable]$Details = @{}
    )

    try {
        if (-not (Test-Path -LiteralPath $script:DataPath)) {
            New-Item -ItemType Directory -Path $script:DataPath -Force | Out-Null
        }

        $record = [ordered]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            event        = $Event
            machine      = $env:COMPUTERNAME
            user         = [Environment]::UserName
            sessionId    = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
            details      = $Details
        }
        $line = $record | ConvertTo-Json -Compress -Depth 6
        Add-Content -LiteralPath (Join-Path $script:DataPath 'events.jsonl') -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never turn a recoverable configuration issue into a lock loop.
    }
}

function Test-ByteArrayEqual {
    param(
        [byte[]]$Left,
        [byte[]]$Right
    )

    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) {
        return $false
    }

    [int]$difference = 0
    for ($i = 0; $i -lt $Left.Length; $i++) {
        $difference = $difference -bor ($Left[$i] -bxor $Right[$i])
    }
    return ($difference -eq 0)
}

function Test-GuardCode {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)]$CodeConfig
    )

    try {
        $salt = [Convert]::FromBase64String([string]$CodeConfig.Salt)
        $expected = [Convert]::FromBase64String([string]$CodeConfig.Hash)
        $iterations = [int]$CodeConfig.Iterations
        $derive = New-Object Security.Cryptography.Rfc2898DeriveBytes($Candidate, $salt, $iterations)
        try {
            $actual = $derive.GetBytes($expected.Length)
            return (Test-ByteArrayEqual -Left $actual -Right $expected)
        }
        finally {
            $derive.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Read-ChallengeMarker {
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    $markerPath = Join-Path $FolderPath '.ca-guard.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Remove-OwnedChallenge {
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][string]$InstallationId
    )

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        return $true
    }

    $marker = Read-ChallengeMarker -FolderPath $FolderPath
    if ($null -eq $marker -or [string]$marker.installationId -ne $InstallationId) {
        return $false
    }

    $markerPath = Join-Path $FolderPath '.ca-guard.json'
    $entries = @(Get-ChildItem -Force -LiteralPath $FolderPath)
    if ($entries.Count -ne 1 -or $entries[0].FullName -ne $markerPath) {
        return $false
    }

    Remove-Item -Force -LiteralPath $markerPath
    Remove-Item -LiteralPath $FolderPath
    return $true
}

function Send-FailureWebhook {
    param(
        [string]$WebhookUrl,
        [Parameter(Mandatory = $true)][hashtable]$Payload
    )

    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
        return
    }

    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' `
            -Body ($Payload | ConvertTo-Json -Depth 5) -TimeoutSec 5 | Out-Null
        Write-GuardEvent -Event 'webhook_sent'
    }
    catch {
        Write-GuardEvent -Event 'webhook_failed' -Details @{ message = $_.Exception.Message }
    }
}

function Lock-Workstation {
    if ($NoLock) {
        Write-GuardEvent -Event 'lock_suppressed_for_test'
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CAWorkstation {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool LockWorkStation();
}
'@
    [void][CAWorkstation]::LockWorkStation()
}

function Show-PendingAlert {
    param([string]$AlertPath)

    if (-not (Test-Path -LiteralPath $AlertPath -PathType Leaf)) {
        return
    }

    try {
        $alert = Get-Content -Raw -LiteralPath $AlertPath | ConvertFrom-Json
        if (-not $NoUi) {
            Add-Type -AssemblyName System.Windows.Forms
            $message = "A previous CA Guard challenge was not completed.`r`n`r`nUTC: $($alert.timestampUtc)`r`nReason: $($alert.reason)"
            [void][System.Windows.Forms.MessageBox]::Show(
                $message,
                'CA Guard security alert',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }
        Remove-Item -Force -LiteralPath $AlertPath
        Write-GuardEvent -Event 'previous_alert_acknowledged'
    }
    catch {
        Write-GuardEvent -Event 'alert_display_failed' -Details @{ message = $_.Exception.Message }
    }
}

function Wait-ForChallengeHeadless {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $tamperLogged = $false
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $folderExists = Test-Path -LiteralPath $FolderPath -PathType Container
        if ($Mode -eq 'FolderDelete' -and -not $folderExists) {
            return 'success'
        }
        if ($Mode -in @('Code', 'CodeAndFace') -and -not $folderExists -and -not $tamperLogged) {
            Write-GuardEvent -Event 'challenge_folder_removed_without_code'
            $tamperLogged = $true
        }
        Start-Sleep -Milliseconds 200
    }
    return 'timeout'
}

function Start-FaceVerification {
    param(
        [Parameter(Mandatory = $true)]$FaceConfig,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $pythonPath = [string]$FaceConfig.PythonPath
    $scriptPath = [string]$FaceConfig.ScriptPath
    $modelPath = [string]$FaceConfig.ModelPath
    foreach ($path in @($pythonPath, $scriptPath, $modelPath)) {
        if ([string]::IsNullOrWhiteSpace($path) -or $path.Contains('"')) {
            throw 'Face verification contains an invalid path.'
        }
    }
    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
        throw "Face Python runtime was not found: $pythonPath"
    }
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Face helper was not found: $scriptPath"
    }
    if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
        throw "Enrolled face model was not found: $modelPath"
    }

    $cameraIndex = [int]$FaceConfig.CameraIndex
    $threshold = [double]$FaceConfig.Threshold
    $requiredMatches = [int]$FaceConfig.RequiredMatches
    $windowSize = [int]$FaceConfig.WindowSize
    $argumentLine = @(
        ('"{0}"' -f $scriptPath),
        'verify',
        '--model', ('"{0}"' -f $modelPath),
        '--camera-index', $cameraIndex,
        '--timeout', $TimeoutSeconds,
        '--threshold', $threshold.ToString([Globalization.CultureInfo]::InvariantCulture),
        '--required-matches', $requiredMatches,
        '--window-size', $windowSize
    ) -join ' '

    return Start-Process -FilePath $pythonPath -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
}

function Wait-ForChallengeWindow {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        $CodeConfig,
        $FaceConfig
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $state = @{
        AllowClose   = $false
        Outcome      = $null
        Attempts     = 0
        TamperLogged = $false
        PinVerified  = $false
        FaceProcess  = $null
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'CA Unlock Guard'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object Drawing.Size(520, 290)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false
    $form.TopMost = $true
    $form.ShowInTaskbar = $true

    $title = New-Object System.Windows.Forms.Label
    $title.Location = New-Object Drawing.Point(22, 18)
    $title.Size = New-Object Drawing.Size(460, 32)
    $title.Font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold)
    $title.Text = 'Owner verification required'
    $form.Controls.Add($title)

    $instruction = New-Object System.Windows.Forms.Label
    $instruction.Location = New-Object Drawing.Point(24, 61)
    $instruction.Size = New-Object Drawing.Size(458, 55)
    if ($Mode -eq 'Code') {
        $instruction.Text = 'Enter your private CA Guard code. Deleting the desktop folder alone does not verify the owner.'
    }
    elseif ($Mode -eq 'CodeAndFace') {
        $instruction.Text = 'Enter your private Guard code, then look at the camera. Both checks are required.'
    }
    else {
        $instruction.Text = 'Delete the CA folder from your Desktop before the countdown reaches zero.'
    }
    $form.Controls.Add($instruction)

    $countdown = New-Object System.Windows.Forms.Label
    $countdown.Location = New-Object Drawing.Point(408, 18)
    $countdown.Size = New-Object Drawing.Size(72, 32)
    $countdown.TextAlign = 'MiddleRight'
    $countdown.Font = New-Object Drawing.Font('Consolas', 14, [Drawing.FontStyle]::Bold)
    $form.Controls.Add($countdown)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object Drawing.Point(24, 181)
    $status.Size = New-Object Drawing.Size(458, 28)
    $status.ForeColor = [Drawing.Color]::DarkRed
    $form.Controls.Add($status)

    $openDesktop = New-Object System.Windows.Forms.Button
    $openDesktop.Location = New-Object Drawing.Point(332, 213)
    $openDesktop.Size = New-Object Drawing.Size(150, 30)
    $openDesktop.Text = 'Open Desktop'
    $openDesktop.Add_Click({
        Start-Process explorer.exe -ArgumentList "/select,`"$FolderPath`""
    })
    $form.Controls.Add($openDesktop)

    $codeBox = $null
    $submit = $null
    if ($Mode -in @('Code', 'CodeAndFace')) {
        $codeBox = New-Object System.Windows.Forms.TextBox
        $codeBox.Location = New-Object Drawing.Point(24, 125)
        $codeBox.Size = New-Object Drawing.Size(340, 30)
        $codeBox.UseSystemPasswordChar = $true
        $codeBox.Font = New-Object Drawing.Font('Segoe UI', 11)
        $form.Controls.Add($codeBox)

        $submit = New-Object System.Windows.Forms.Button
        $submit.Location = New-Object Drawing.Point(376, 124)
        $submit.Size = New-Object Drawing.Size(106, 31)
        $submit.Text = 'Verify'
        $submit.Add_Click({
            if ($state.PinVerified -and $Mode -eq 'CodeAndFace') {
                $remainingForFace = [Math]::Floor($TimeoutSeconds - $stopwatch.Elapsed.TotalSeconds)
                if ($remainingForFace -lt 2) {
                    $state.Outcome = 'timeout'
                    $state.AllowClose = $true
                    $form.Close()
                    return
                }
                try {
                    $state.FaceProcess = Start-FaceVerification -FaceConfig $FaceConfig -TimeoutSeconds $remainingForFace
                    $submit.Enabled = $false
                    $status.Text = 'PIN accepted. Look at the camera window.'
                    $form.TopMost = $false
                }
                catch {
                    Write-GuardEvent -Event 'face_start_failed' -Details @{ message = $_.Exception.Message }
                    $status.Text = 'Could not start the camera check. You may retry before timeout.'
                }
                return
            }

            if (Test-GuardCode -Candidate $codeBox.Text -CodeConfig $CodeConfig) {
                if ($Mode -eq 'Code') {
                    $state.Outcome = 'success'
                    $state.AllowClose = $true
                    $form.Close()
                    return
                }

                $state.PinVerified = $true
                $codeBox.Enabled = $false
                $submit.Text = 'Retry face'
                $remainingForFace = [Math]::Floor($TimeoutSeconds - $stopwatch.Elapsed.TotalSeconds)
                if ($remainingForFace -lt 2) {
                    $state.Outcome = 'timeout'
                    $state.AllowClose = $true
                    $form.Close()
                    return
                }
                try {
                    $state.FaceProcess = Start-FaceVerification -FaceConfig $FaceConfig -TimeoutSeconds $remainingForFace
                    $submit.Enabled = $false
                    $status.Text = 'PIN accepted. Look at the camera window.'
                    $form.TopMost = $false
                }
                catch {
                    Write-GuardEvent -Event 'face_start_failed' -Details @{ message = $_.Exception.Message }
                    $status.Text = 'Could not start the camera check. You may retry before timeout.'
                }
                return
            }

            $state.Attempts++
            Write-GuardEvent -Event 'wrong_code' -Details @{ attempt = $state.Attempts }
            $codeBox.Clear()
            if ($state.Attempts -ge 3) {
                $state.Outcome = 'too_many_attempts'
                $state.AllowClose = $true
                $form.Close()
            }
            else {
                $status.Text = "Incorrect code. Attempts remaining: $([Math]::Max(0, 3 - $state.Attempts))"
                $codeBox.Focus()
            }
        })
        $form.AcceptButton = $submit
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
        $remaining = [Math]::Max(0, [Math]::Ceiling($TimeoutSeconds - $stopwatch.Elapsed.TotalSeconds))
        $countdown.Text = ('00:{0:00}' -f $remaining)

        if ($null -ne $state.FaceProcess -and $state.FaceProcess.HasExited) {
            $faceExitCode = $state.FaceProcess.ExitCode
            $state.FaceProcess.Dispose()
            $state.FaceProcess = $null
            if ($faceExitCode -eq 0) {
                Write-GuardEvent -Event 'face_succeeded'
                $state.Outcome = 'success'
                $state.AllowClose = $true
                $form.Close()
                return
            }

            Write-GuardEvent -Event 'face_failed' -Details @{ exitCode = $faceExitCode }
            $submit.Enabled = $true
            $form.TopMost = $true
            $status.Text = "Face was not verified (code $faceExitCode). Click Retry face."
        }

        $folderExists = Test-Path -LiteralPath $FolderPath -PathType Container
        if ($Mode -eq 'FolderDelete' -and -not $folderExists) {
            $state.Outcome = 'success'
            $state.AllowClose = $true
            $form.Close()
            return
        }

        if ($Mode -in @('Code', 'CodeAndFace') -and -not $folderExists -and -not $state.TamperLogged) {
            $state.TamperLogged = $true
            $status.Text = 'Folder removal was recorded. The private code is still required.'
            Write-GuardEvent -Event 'challenge_folder_removed_without_code'
        }

        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            if ($null -ne $state.FaceProcess -and -not $state.FaceProcess.HasExited) {
                try { $state.FaceProcess.Kill() } catch {}
            }
            $state.Outcome = 'timeout'
            $state.AllowClose = $true
            $form.Close()
        }
    })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if (-not $state.AllowClose) {
            $eventArgs.Cancel = $true
        }
    })
    $form.Add_Shown({
        $timer.Start()
        if ($null -ne $codeBox) {
            $codeBox.Focus()
        }
    })

    try {
        [void]$form.ShowDialog()
    }
    finally {
        if ($null -ne $state.FaceProcess) {
            if (-not $state.FaceProcess.HasExited) {
                try { $state.FaceProcess.Kill() } catch {}
            }
            $state.FaceProcess.Dispose()
        }
        $timer.Stop()
        $timer.Dispose()
        $form.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace([string]$state.Outcome)) {
        return 'timeout'
    }
    return [string]$state.Outcome
}

try {
    $script:DataPath = if ($DataPathOverride) { $DataPathOverride } else { Get-DefaultDataPath }
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $script:DataPath 'config.json'
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file was not found: $ConfigPath"
    }

    $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    $mode = [string]$config.Mode
    $faceConfig = if ($null -ne $config.PSObject.Properties['Face']) { $config.Face } else { $null }
    if ($mode -notin @('Code', 'CodeAndFace', 'FolderDelete')) {
        throw "Unsupported verification mode: $mode"
    }
    if ($mode -in @('Code', 'CodeAndFace') -and $null -eq $config.Code) {
        throw "$mode mode requires a code configuration."
    }
    if ($mode -eq 'CodeAndFace' -and $null -eq $faceConfig) {
        throw 'CodeAndFace mode requires a face configuration.'
    }

    $timeoutSeconds = if ($TimeoutSecondsOverride -gt 0) { $TimeoutSecondsOverride } else { [int]$config.TimeoutSeconds }
    if ($timeoutSeconds -lt 1 -or $timeoutSeconds -gt 600) {
        throw 'TimeoutSeconds must be between 1 and 600.'
    }

    $desktopPath = if ($DesktopPathOverride) { $DesktopPathOverride } else { [Environment]::GetFolderPath('Desktop') }
    if (-not (Test-Path -LiteralPath $desktopPath -PathType Container)) {
        throw "Desktop path is unavailable: $desktopPath"
    }

    $folderName = [string]$config.FolderName
    if ([string]::IsNullOrWhiteSpace($folderName) -or $folderName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw 'FolderName is invalid.'
    }

    $installationId = [string]$config.InstallationId
    if ([string]::IsNullOrWhiteSpace($installationId)) {
        throw 'InstallationId is missing.'
    }

    $mutexName = "Local\CAUnlockGuard-$installationId"
    $createdNew = $false
    $script:Mutex = New-Object Threading.Mutex($true, $mutexName, [ref]$createdNew)
    $script:HasMutex = $createdNew
    if (-not $createdNew) {
        Write-GuardEvent -Event 'duplicate_instance_ignored'
        exit 0
    }

    $challengePath = Join-Path $desktopPath $folderName
    if (Test-Path -LiteralPath $challengePath) {
        $existingMarker = Read-ChallengeMarker -FolderPath $challengePath
        if ($null -eq $existingMarker -or [string]$existingMarker.installationId -ne $installationId) {
            Write-GuardEvent -Event 'desktop_folder_collision' -Details @{ path = $challengePath }
            exit 3
        }
        if (-not (Remove-OwnedChallenge -FolderPath $challengePath -InstallationId $installationId)) {
            Write-GuardEvent -Event 'stale_challenge_cleanup_skipped' -Details @{ path = $challengePath }
            exit 3
        }
    }

    New-Item -ItemType Directory -Path $challengePath | Out-Null
    $challengeId = [Guid]::NewGuid().ToString('N')
    $marker = [ordered]@{
        installationId = $installationId
        challengeId     = $challengeId
        createdUtc      = [DateTime]::UtcNow.ToString('o')
    }
    $markerPath = Join-Path $challengePath '.ca-guard.json'
    $marker | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding UTF8
    try { (Get-Item -Force -LiteralPath $markerPath).Attributes = 'Hidden' } catch {}

    Write-GuardEvent -Event 'challenge_started' -Details @{ challengeId = $challengeId; mode = $mode; timeoutSeconds = $timeoutSeconds }

    $outcome = if ($NoUi) {
        Wait-ForChallengeHeadless -Mode $mode -FolderPath $challengePath -TimeoutSeconds $timeoutSeconds
    }
    else {
        Wait-ForChallengeWindow -Mode $mode -FolderPath $challengePath -TimeoutSeconds $timeoutSeconds -CodeConfig $config.Code -FaceConfig $faceConfig
    }

    if ($outcome -eq 'success') {
        if ($mode -in @('Code', 'CodeAndFace')) {
            $cleaned = Remove-OwnedChallenge -FolderPath $challengePath -InstallationId $installationId
            if (-not $cleaned -and (Test-Path -LiteralPath $challengePath)) {
                Write-GuardEvent -Event 'authorized_cleanup_skipped' -Details @{ path = $challengePath }
            }
        }
        Write-GuardEvent -Event 'challenge_succeeded' -Details @{ challengeId = $challengeId; mode = $mode }
        Show-PendingAlert -AlertPath (Join-Path $script:DataPath 'pending-alert.json')
        exit 0
    }

    $failure = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        reason       = $outcome
        machine      = $env:COMPUTERNAME
        user         = [Environment]::UserName
        challengeId  = $challengeId
    }
    $failure | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:DataPath 'pending-alert.json') -Encoding UTF8
    Write-GuardEvent -Event 'challenge_failed' -Details @{ challengeId = $challengeId; reason = $outcome }

    $webhook = if ($null -ne $config.WebhookUrl) { [string]$config.WebhookUrl } else { '' }
    Send-FailureWebhook -WebhookUrl $webhook -Payload $failure
    Lock-Workstation
    exit 2
}
catch {
    if (-not $script:DataPath) {
        $script:DataPath = Get-DefaultDataPath
    }
    Write-GuardEvent -Event 'guard_error_fail_open' -Details @{ message = $_.Exception.Message; type = $_.Exception.GetType().FullName }
    Write-Error "CA Unlock Guard failed open: $($_.Exception.Message)"
    exit 10
}
finally {
    if ($script:HasMutex -and $null -ne $script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $script:Mutex) {
        $script:Mutex.Dispose()
    }
}
