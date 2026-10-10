[CmdletBinding()]
param(
    [ValidateSet(
        'ControlPanel', 'StartAll', 'StopAll', 'StartCamera', 'StopCamera',
        'StartOverlay', 'StopOverlay', 'OpenOverlaySettings', 'ApplyGpu', 'ResetGpu',
        'EnableAutoStart', 'DisableAutoStart', 'Status'
    )]
    [string]$Action = 'ControlPanel',

    [switch]$ConfirmHardwareRisk
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$presenceTaskName = 'CA Presence Monitor (NO LOCK)'
$overlayTaskName = 'CA System Overlay'
$gpuTaskName = 'CA GPU Limits'
$gpuResetTaskName = 'CA GPU Limits Reset'
$nvidiaSmi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
$gpuInstallPath = Join-Path $env:ProgramData 'CAGpuLimits'
$gpuHelperPath = Join-Path $gpuInstallPath 'CAGpuHelper.exe'
$gpuStatePath = Join-Path $gpuInstallPath 'gpu-limits-state.json'
$overlaySettingsPath = Join-Path $env:LOCALAPPDATA 'CAAutoConfig\settings.json'

function Start-CameraMonitor {
    $task = Get-ScheduledTask -TaskName $presenceTaskName -ErrorAction SilentlyContinue
    if ($null -ne $task -and [string]$task.State -ne 'Running') {
        Start-ScheduledTask -TaskName $presenceTaskName
    }
}

function Stop-CameraMonitor {
    $task = Get-ScheduledTask -TaskName $presenceTaskName -ErrorAction SilentlyContinue
    if ($null -ne $task -and [string]$task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $presenceTaskName
    }
}

function Start-SystemOverlay {
    $task = Get-ScheduledTask -TaskName $overlayTaskName -ErrorAction Stop
    if ([string]$task.State -ne 'Running') {
        Start-ScheduledTask -TaskName $overlayTaskName
    }
}

function Stop-SystemOverlay {
    $task = Get-ScheduledTask -TaskName $overlayTaskName -ErrorAction SilentlyContinue
    if ($null -ne $task -and [string]$task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $overlayTaskName
    }
}

function Open-SystemOverlaySettings {
    Start-SystemOverlay
    $eventName = 'Local\CA-SystemOverlay-OpenSettings'
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $request = [Threading.EventWaitHandle]::OpenExisting($eventName)
            try { $request.Set() | Out-Null }
            finally { $request.Dispose() }
            return
        }
        catch [Threading.WaitHandleCannotBeOpenedException] {
            Start-Sleep -Milliseconds 100
        }
    }
    throw 'The HUD started, but its settings channel did not become ready. Try again in a moment.'
}

function Invoke-FixedGpuTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$ExpectedStatus
    )
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        throw "The approved GPU task is not installed: $TaskName"
    }
    $previousTimestamp = ''
    if (Test-Path -LiteralPath $gpuStatePath -PathType Leaf) {
        try { $previousTimestamp = [string](Get-Content -Raw -LiteralPath $gpuStatePath | ConvertFrom-Json).timestampUtc }
        catch { $previousTimestamp = '' }
    }
    Start-ScheduledTask -TaskName $TaskName
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 400
        if (-not (Test-Path -LiteralPath $gpuStatePath -PathType Leaf)) { continue }
        try {
            $state = Get-Content -Raw -LiteralPath $gpuStatePath | ConvertFrom-Json
            if ([string]$state.timestampUtc -eq $previousTimestamp) { continue }
            if ([string]$state.status -eq $ExpectedStatus) { return }
            if ([string]$state.status -eq 'failed') { throw "GPU task failed: $($state.message)" }
        }
        catch {
            if ($_.Exception.Message -like 'GPU task failed:*') { throw }
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "The GPU task '$TaskName' did not publish a fresh result within 30 seconds."
}

function Apply-GpuLimits { Invoke-FixedGpuTask -TaskName $gpuTaskName -ExpectedStatus 'applied' }

function Reset-GpuLimits { Invoke-FixedGpuTask -TaskName $gpuResetTaskName -ExpectedStatus 'reset' }

function Assert-HardwareConfirmation {
    if (-not $ConfirmHardwareRisk) {
        throw 'This command changes GPU driver state. Review it and rerun with -ConfirmHardwareRisk.'
    }
}

function Set-AutoStart {
    param([bool]$Enabled)
    $presence = Get-ScheduledTask -TaskName $presenceTaskName -ErrorAction SilentlyContinue
    $overlay = Get-ScheduledTask -TaskName $overlayTaskName -ErrorAction Stop
    if ($null -ne $presence) {
        if ($Enabled) { Enable-ScheduledTask -InputObject $presence | Out-Null }
        else { Disable-ScheduledTask -InputObject $presence | Out-Null }
    }
    if ($Enabled) { Enable-ScheduledTask -InputObject $overlay | Out-Null }
    else { Disable-ScheduledTask -InputObject $overlay | Out-Null }
}

function Get-CombinedStatusText {
    $lines = [Collections.Generic.List[string]]::new()
    $presence = Get-ScheduledTask -TaskName $presenceTaskName -ErrorAction SilentlyContinue
    if ($null -eq $presence) {
        $lines.Add('Camera monitor: NOT INSTALLED')
    }
    else {
        $enabled = [string]$presence.State -ne 'Disabled'
        $lines.Add("Camera monitor: $($presence.State) | auto-start=$enabled | starts minimized")
    }

    $overlay = Get-ScheduledTask -TaskName $overlayTaskName -ErrorAction SilentlyContinue
    if ($null -eq $overlay) {
        $lines.Add('Hardware HUD: NOT INSTALLED')
    }
    else {
        $overlayEnabled = [string]$overlay.State -ne 'Disabled'
        $targetDisplay = 'install default'
        $shortcut = 'Ctrl+Alt+L'
        $overlayArguments = [string]$overlay.Actions.Arguments
        if ($overlayArguments -match '(?:--display|-TargetDeviceName)\s+(?:"|&quot;)([^"&\s]+)(?:"|&quot;)') {
            $targetDisplay = [string]$Matches[1]
        }
        if (Test-Path -LiteralPath $overlaySettingsPath -PathType Leaf) {
            try {
                $overlaySettings = Get-Content -Raw -LiteralPath $overlaySettingsPath | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace([string]$overlaySettings.TargetDeviceName)) {
                    $targetDisplay = [string]$overlaySettings.TargetDeviceName
                }
                $shortcut = 'custom'
            }
            catch { }
        }
        $lines.Add("Hardware HUD: $($overlay.State) | auto-start=$overlayEnabled | display=$targetDisplay | shortcut=$shortcut")
    }

    if (Test-Path -LiteralPath $nvidiaSmi -PathType Leaf) {
        $expectedByUuid = @{}
        $expectedByIndex = @{}
        if (Test-Path -LiteralPath $gpuStatePath -PathType Leaf) {
            try {
                $gpuState = Get-Content -Raw -LiteralPath $gpuStatePath | ConvertFrom-Json
                $stateStatus = $gpuState.PSObject.Properties['status']
                $stateProfiles = $gpuState.PSObject.Properties['results']
                if ($null -ne $stateStatus -and [string]$stateStatus.Value -eq 'applied' -and $null -ne $stateProfiles) {
                    foreach ($profile in @($stateProfiles.Value)) {
                        $indexProperty = $profile.PSObject.Properties['index']
                        $uuidProperty = $profile.PSObject.Properties['uuid']
                        $powerProperty = $profile.PSObject.Properties['powerLimitWatts']
                        $clockProperty = $profile.PSObject.Properties['maxGraphicsClockMHz']
                        if ($null -eq $powerProperty -or $null -eq $clockProperty) { continue }
                        $expected = [pscustomobject]@{
                            PowerLimitWatts = [double]$powerProperty.Value
                            MaxClockMHz      = [int]$clockProperty.Value
                        }
                        if ($null -ne $uuidProperty -and [string]$uuidProperty.Value -match '^GPU-[0-9A-Fa-f-]+$') {
                            $expectedByUuid[[string]$uuidProperty.Value] = $expected
                        }
                        elseif ($null -ne $indexProperty -and [int]$indexProperty.Value -ge 0) {
                            $expectedByIndex[[int]$indexProperty.Value] = $expected
                        }
                    }
                }
            }
            catch { }
        }

        $gpuLines = @(& $nvidiaSmi --query-gpu=index,uuid,power.limit,power.default_limit,clocks.gr --format=csv,noheader,nounits)
        foreach ($line in $gpuLines) {
            $parts = @($line -split ',' | ForEach-Object { $_.Trim() })
            if ($parts.Count -ge 5) {
                $index = [int]$parts[0]
                $uuid = [string]$parts[1]
                $currentPower = [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture)
                $currentClock = -1
                [void][int]::TryParse($parts[4], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$currentClock)
                $expected = if ($expectedByUuid.ContainsKey($uuid)) { $expectedByUuid[$uuid] } elseif ($expectedByIndex.ContainsKey($index)) { $expectedByIndex[$index] } else { $null }
                if ($null -eq $expected) {
                    $profileStatus = 'unmanaged'
                }
                else {
                    $powerMatches = [Math]::Abs($currentPower - [double]$expected.PowerLimitWatts) -le 0.5
                    $clockMatches = $currentClock -ge 0 -and $currentClock -le ([int]$expected.MaxClockMHz + 30)
                    $profileStatus = if ($powerMatches -and $clockMatches) { 'yes' } else { 'no' }
                }
                $lines.Add("GPU $index ($uuid): power=$($parts[2])W (default $($parts[3])W), clock=$($parts[4])MHz, limits-active=$profileStatus")
            }
        }
    }
    else {
        $lines.Add('GPU limits: nvidia-smi not found')
    }

    $gpuApplyTask = Get-ScheduledTask -TaskName $gpuTaskName -ErrorAction SilentlyContinue
    $gpuAutoEnabled = $null -ne $gpuApplyTask -and [string]$gpuApplyTask.State -ne 'Disabled'
    $gpuInstalled = (Test-Path -LiteralPath $gpuHelperPath -PathType Leaf) -and
        $null -ne (Get-ScheduledTask -TaskName $gpuTaskName -ErrorAction SilentlyContinue) -and
        $null -ne (Get-ScheduledTask -TaskName $gpuResetTaskName -ErrorAction SilentlyContinue)
    $lines.Add("GPU helper: installed=$gpuInstalled | auto-start=$gpuAutoEnabled | fixed apply/reset SYSTEM tasks")
    $lines.Add('Windows lock integration: DISABLED')
    return $lines -join [Environment]::NewLine
}

switch ($Action) {
    'StartAll' {
        Assert-HardwareConfirmation
        Start-CameraMonitor
        Start-SystemOverlay
        Apply-GpuLimits
        return
    }
    'StopAll' {
        Assert-HardwareConfirmation
        Stop-CameraMonitor
        Stop-SystemOverlay
        Reset-GpuLimits
        return
    }
    'StartCamera' { Start-CameraMonitor; return }
    'StopCamera' { Stop-CameraMonitor; return }
    'StartOverlay' { Start-SystemOverlay; return }
    'StopOverlay' { Stop-SystemOverlay; return }
    'OpenOverlaySettings' { Open-SystemOverlaySettings; return }
    'ApplyGpu' { Assert-HardwareConfirmation; Apply-GpuLimits; return }
    'ResetGpu' { Assert-HardwareConfirmation; Reset-GpuLimits; return }
    'EnableAutoStart' { Set-AutoStart -Enabled $true; return }
    'DisableAutoStart' { Set-AutoStart -Enabled $false; return }
    'Status' { Get-CombinedStatusText; return }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = 'CA AutoConfig'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(650, 560)
$form.MinimumSize = New-Object Drawing.Size(650, 560)
$form.AutoScaleMode = 'Dpi'
$form.BackColor = [Drawing.Color]::FromArgb(24, 27, 33)
$form.ForeColor = [Drawing.Color]::White
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

$title = New-Object Windows.Forms.Label
$title.Text = 'CA AutoConfig'
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 20)
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(24, 18)
$form.Controls.Add($title)

$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = 'Presence monitor  ·  hardware HUD  ·  NVIDIA limits'
$subtitle.ForeColor = [Drawing.Color]::FromArgb(170, 178, 190)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object Drawing.Point(28, 58)
$form.Controls.Add($subtitle)

$statusBox = New-Object Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.ScrollBars = 'Vertical'
$statusBox.BackColor = [Drawing.Color]::FromArgb(35, 39, 47)
$statusBox.ForeColor = [Drawing.Color]::FromArgb(225, 230, 238)
$statusBox.BorderStyle = 'FixedSingle'
$statusBox.Location = New-Object Drawing.Point(28, 92)
$statusBox.Size = New-Object Drawing.Size(575, 175)
$statusBox.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.Controls.Add($statusBox)

function New-ControlButton {
    param([string]$Text, [int]$X, [int]$Y, [Drawing.Color]$Color, [scriptblock]$OnClick)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object Drawing.Point($X, $Y)
    $button.Size = New-Object Drawing.Size(175, 42)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $Color
    $button.ForeColor = [Drawing.Color]::White
    $button.Add_Click($OnClick)
    $form.Controls.Add($button)
}

function Refresh-ControlStatus {
    $statusBox.Text = Get-CombinedStatusText
}

function Invoke-UiAction {
    param([scriptblock]$Operation)
    try {
        $form.UseWaitCursor = $true
        & $Operation
        Refresh-ControlStatus
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'CA AutoConfig', 'OK', 'Error') | Out-Null
    }
    finally {
        $form.UseWaitCursor = $false
    }
}

function Confirm-UiGpuAction {
    param([Parameter(Mandatory = $true)][string]$Message)
    $choice = [Windows.Forms.MessageBox]::Show(
        $Message,
        'CA AutoConfig - confirm GPU change',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning,
        [Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    return $choice -eq [Windows.Forms.DialogResult]::Yes
}

New-ControlButton 'Start all' 28 292 ([Drawing.Color]::FromArgb(27, 138, 91)) {
    if (Confirm-UiGpuAction 'Apply the installed, UUID-pinned GPU profile now?') {
        Invoke-UiAction { Start-CameraMonitor; Start-SystemOverlay; Apply-GpuLimits }
    }
}
New-ControlButton 'Stop all' 224 292 ([Drawing.Color]::FromArgb(181, 63, 63)) {
    if (Confirm-UiGpuAction 'Stop the monitors and restore the exact pre-apply GPU power limits and vendor-managed clocks?') {
        Invoke-UiAction { Stop-CameraMonitor; Stop-SystemOverlay; Reset-GpuLimits }
    }
}
New-ControlButton 'Refresh status' 420 292 ([Drawing.Color]::FromArgb(70, 83, 105)) { Refresh-ControlStatus }
New-ControlButton 'Start camera' 28 346 ([Drawing.Color]::FromArgb(52, 96, 153)) { Invoke-UiAction { Start-CameraMonitor } }
New-ControlButton 'Stop camera' 224 346 ([Drawing.Color]::FromArgb(88, 92, 102)) { Invoke-UiAction { Stop-CameraMonitor } }
New-ControlButton 'Start HUD' 420 346 ([Drawing.Color]::FromArgb(52, 96, 153)) { Invoke-UiAction { Start-SystemOverlay } }
New-ControlButton 'Stop HUD' 28 400 ([Drawing.Color]::FromArgb(88, 92, 102)) { Invoke-UiAction { Stop-SystemOverlay } }
New-ControlButton 'Apply GPU limits' 224 400 ([Drawing.Color]::FromArgb(52, 96, 153)) {
    if (Confirm-UiGpuAction 'Apply the installed, UUID-pinned GPU profile now?') { Invoke-UiAction { Apply-GpuLimits } }
}
New-ControlButton 'Rollback GPU profile' 420 400 ([Drawing.Color]::FromArgb(88, 92, 102)) {
    if (Confirm-UiGpuAction 'Restore the exact pre-apply GPU power limits and vendor-managed clocks?') { Invoke-UiAction { Reset-GpuLimits } }
}
New-ControlButton 'Auto-start HUD/camera' 28 454 ([Drawing.Color]::FromArgb(88, 92, 102)) { Invoke-UiAction { Set-AutoStart $true } }
New-ControlButton 'Pause HUD/camera' 224 454 ([Drawing.Color]::FromArgb(88, 92, 102)) { Invoke-UiAction { Set-AutoStart $false } }
New-ControlButton 'HUD settings' 420 454 ([Drawing.Color]::FromArgb(52, 96, 153)) { Invoke-UiAction { Open-SystemOverlaySettings } }

Refresh-ControlStatus
[void]$form.ShowDialog()
