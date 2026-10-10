[CmdletBinding()]
param(
    [ValidateSet(
        'ControlPanel', 'StartAll', 'StopAll', 'StartCamera', 'StopCamera',
        'StartOverlay', 'StopOverlay', 'OpenOverlaySettings', 'ApplyGpu', 'ResetGpu',
        'EnableAutoStart', 'DisableAutoStart', 'Status'
    )]
    [string]$Action = 'ControlPanel',

    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$presenceTaskName = 'CA Presence Monitor (NO LOCK)'
$overlayTaskName = 'CA System Overlay'
$gpuTaskName = 'CA GPU Limits'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$nvidiaSmi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
$gpuInstallPath = Join-Path $env:ProgramData 'CAGpuLimits'
$gpuApplyScript = Join-Path $gpuInstallPath 'Apply-GpuLimits.ps1'
$gpuStatePath = Join-Path $gpuInstallPath 'gpu-limits-state.json'
$gpuAutoStatePath = Join-Path $gpuInstallPath 'autostart-state.json'
$overlaySettingsPath = Join-Path $env:LOCALAPPDATA 'CAAutoConfig\settings.json'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

function Invoke-ElevatedControl {
    param([Parameter(Mandatory = $true)][string]$ElevatedAction)
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action $ElevatedAction -Elevated"
    $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "Elevated action '$ElevatedAction' failed or was cancelled (exit $($process.ExitCode))."
    }
}

function Assert-Admin {
    if (-not $isAdmin -or -not $Elevated) {
        throw 'This internal action requires an elevated process.'
    }
}

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

function Set-GpuAutoState {
    param([bool]$Enabled)
    [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        enabled      = $Enabled
    } | ConvertTo-Json | Set-Content -LiteralPath $gpuAutoStatePath -Encoding UTF8
}

function Apply-GpuLimits {
    $task = Get-ScheduledTask -TaskName $gpuTaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        throw "The approved GPU task is not installed: $gpuTaskName"
    }
    $previousTimestamp = ''
    if (Test-Path -LiteralPath $gpuStatePath -PathType Leaf) {
        try { $previousTimestamp = [string](Get-Content -Raw -LiteralPath $gpuStatePath | ConvertFrom-Json).timestampUtc }
        catch { $previousTimestamp = '' }
    }
    Start-ScheduledTask -TaskName $gpuTaskName
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 400
        if (-not (Test-Path -LiteralPath $gpuStatePath -PathType Leaf)) { continue }
        try {
            $state = Get-Content -Raw -LiteralPath $gpuStatePath | ConvertFrom-Json
            if ([string]$state.timestampUtc -eq $previousTimestamp) { continue }
            if ([string]$state.status -eq 'applied') { return }
            if ([string]$state.status -eq 'failed') { throw "GPU task failed: $($state.message)" }
        }
        catch {
            if ($_.Exception.Message -like 'GPU task failed:*') { throw }
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The GPU task did not publish a fresh result within 20 seconds.'
}

function Reset-GpuLimits {
    Assert-Admin
    if (-not (Test-Path -LiteralPath $gpuStatePath -PathType Leaf)) {
        throw 'The applied GPU profile state is missing; refusing to guess which GPUs to reset.'
    }
    $state = Get-Content -Raw -LiteralPath $gpuStatePath | ConvertFrom-Json
    $statusProperty = $state.PSObject.Properties['status']
    $profilesProperty = $state.PSObject.Properties['results']
    if ($null -eq $statusProperty -or [string]$statusProperty.Value -ne 'applied' -or
        $null -eq $profilesProperty -or @($profilesProperty.Value).Count -eq 0) {
        throw 'No applied GPU profile is available; refusing to reset guessed GPU indices.'
    }

    $resetTargets = @()
    $seenTargets = @{}
    foreach ($profile in @($profilesProperty.Value)) {
        $uuidProperty = $profile.PSObject.Properties['uuid']
        $indexProperty = $profile.PSObject.Properties['index']
        $uuid = if ($null -ne $uuidProperty) { [string]$uuidProperty.Value } else { '' }
        $profileIndex = -1
        if ($null -ne $indexProperty) { $profileIndex = [int]$indexProperty.Value }
        if (-not [string]::IsNullOrWhiteSpace($uuid)) {
            if ($uuid -notmatch '^GPU-[0-9A-Fa-f-]+$') { throw "The applied profile contains an invalid GPU UUID: $uuid" }
            $target = $uuid
        }
        elseif ($profileIndex -ge 0) {
            # Backward compatibility for profiles created before UUID pinning.
            $target = [string]$profileIndex
        }
        else {
            throw 'The applied profile contains no usable GPU identity.'
        }
        if ($seenTargets.ContainsKey($target)) { throw "The applied profile contains duplicate GPU target $target." }
        $seenTargets[$target] = $true

        $identityText = (& $nvidiaSmi -i $target --query-gpu=index,uuid,power.default_limit --format=csv,noheader,nounits | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "Could not read default power for GPU $target." }
        $identityParts = @($identityText -split ',' | ForEach-Object { $_.Trim() })
        if ($identityParts.Count -lt 3) { throw "Could not verify GPU $target before restoring default power." }
        $actualIndex = [int]::Parse($identityParts[0], [Globalization.CultureInfo]::InvariantCulture)
        $actualUuid = [string]$identityParts[1]
        if ($target -like 'GPU-*' -and -not [string]::Equals($target, $actualUuid, [StringComparison]::OrdinalIgnoreCase)) {
            throw "GPU identity changed while preflighting reset target $target; no reset was attempted."
        }
        $defaultPower = [double]::Parse($identityParts[2], [Globalization.CultureInfo]::InvariantCulture)
        $resetTargets += [pscustomobject]@{
            Target       = $target
            Index        = $actualIndex
            Uuid         = $actualUuid
            DefaultPower = $defaultPower
        }
    }

    $results = @()
    foreach ($resetTarget in $resetTargets) {
        $target = [string]$resetTarget.Target
        & $nvidiaSmi -i $target -rgc | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not reset locked clocks on GPU $target." }
        $defaultPowerText = ([double]$resetTarget.DefaultPower).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
        & $nvidiaSmi -i $target -pl $defaultPowerText | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not restore default power on GPU $target." }
        $results += [ordered]@{
            index                   = [int]$resetTarget.Index
            uuid                    = [string]$resetTarget.Uuid
            restoredPowerLimitWatts = [double]$resetTarget.DefaultPower
            graphicsClockReset      = $true
        }
    }
    [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status       = 'reset'
        computer     = $env:COMPUTERNAME
        results      = $results
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $gpuStatePath -Encoding UTF8
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
    if ($null -ne (Get-ScheduledTask -TaskName $gpuTaskName -ErrorAction SilentlyContinue)) {
        Invoke-ElevatedControl -ElevatedAction $(if ($Enabled) { 'EnableAutoStart' } else { 'DisableAutoStart' })
    }
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

    $gpuAutoEnabled = $true
    if (Test-Path -LiteralPath $gpuAutoStatePath -PathType Leaf) {
        $gpuAutoEnabled = [bool](Get-Content -Raw -LiteralPath $gpuAutoStatePath | ConvertFrom-Json).enabled
    }
    $gpuInstalled = Test-Path -LiteralPath $gpuApplyScript -PathType Leaf
    $lines.Add("GPU startup helper: installed=$gpuInstalled | auto-start=$gpuAutoEnabled | SYSTEM task")
    $lines.Add('Windows lock integration: DISABLED')
    return $lines -join [Environment]::NewLine
}

if ($Elevated) {
    try {
        switch ($Action) {
            'ApplyGpu' { Apply-GpuLimits }
            'ResetGpu' { Reset-GpuLimits }
            'EnableAutoStart' {
                Assert-Admin
                if ($null -ne (Get-ScheduledTask -TaskName $gpuTaskName -ErrorAction SilentlyContinue)) {
                    Enable-ScheduledTask -TaskName $gpuTaskName | Out-Null
                    Set-GpuAutoState -Enabled $true
                }
            }
            'DisableAutoStart' {
                Assert-Admin
                if ($null -ne (Get-ScheduledTask -TaskName $gpuTaskName -ErrorAction SilentlyContinue)) {
                    Disable-ScheduledTask -TaskName $gpuTaskName | Out-Null
                    Set-GpuAutoState -Enabled $false
                }
            }
            default { throw "Unsupported elevated action: $Action" }
        }
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

switch ($Action) {
    'StartAll' {
        Start-CameraMonitor
        Start-SystemOverlay
        Apply-GpuLimits
        return
    }
    'StopAll' {
        Stop-CameraMonitor
        Stop-SystemOverlay
        Invoke-ElevatedControl -ElevatedAction 'ResetGpu'
        return
    }
    'StartCamera' { Start-CameraMonitor; return }
    'StopCamera' { Stop-CameraMonitor; return }
    'StartOverlay' { Start-SystemOverlay; return }
    'StopOverlay' { Stop-SystemOverlay; return }
    'OpenOverlaySettings' { Open-SystemOverlaySettings; return }
    'ApplyGpu' { Apply-GpuLimits; return }
    'ResetGpu' { Invoke-ElevatedControl -ElevatedAction 'ResetGpu'; return }
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

New-ControlButton 'Start all' 28 292 ([Drawing.Color]::FromArgb(27, 138, 91)) { Invoke-UiAction { Start-CameraMonitor; Start-SystemOverlay; Apply-GpuLimits } }
New-ControlButton 'Stop all' 224 292 ([Drawing.Color]::FromArgb(181, 63, 63)) { Invoke-UiAction { Stop-CameraMonitor; Stop-SystemOverlay; Invoke-ElevatedControl 'ResetGpu' } }
New-ControlButton 'Refresh status' 420 292 ([Drawing.Color]::FromArgb(70, 83, 105)) { Refresh-ControlStatus }
New-ControlButton 'Start camera' 28 346 ([Drawing.Color]::FromArgb(52, 96, 153)) { Invoke-UiAction { Start-CameraMonitor } }
New-ControlButton 'Stop camera' 224 346 ([Drawing.Color]::FromArgb(88, 92, 102)) { Invoke-UiAction { Stop-CameraMonitor } }
New-ControlButton 'Start HUD' 420 346 ([Drawing.Color]::FromArgb(52, 96, 153)) { Invoke-UiAction { Start-SystemOverlay } }
New-ControlButton 'Stop HUD' 28 400 ([Drawing.Color]::FromArgb(88, 92, 102)) { Invoke-UiAction { Stop-SystemOverlay } }
New-ControlButton 'Apply GPU limits' 224 400 ([Drawing.Color]::FromArgb(52, 96, 153)) { Invoke-UiAction { Apply-GpuLimits } }
New-ControlButton 'Reset GPU defaults' 420 400 ([Drawing.Color]::FromArgb(88, 92, 102)) { Invoke-UiAction { Invoke-ElevatedControl 'ResetGpu' } }
New-ControlButton 'Enable auto-start' 28 454 ([Drawing.Color]::FromArgb(88, 92, 102)) { Invoke-UiAction { Set-AutoStart $true } }
New-ControlButton 'Disable auto-start' 224 454 ([Drawing.Color]::FromArgb(88, 92, 102)) { Invoke-UiAction { Set-AutoStart $false } }
New-ControlButton 'HUD settings' 420 454 ([Drawing.Color]::FromArgb(52, 96, 153)) { Invoke-UiAction { Open-SystemOverlaySettings } }

Refresh-ControlStatus
[void]$form.ShowDialog()
