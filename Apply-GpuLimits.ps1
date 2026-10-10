[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GpuIndexList,

    [Parameter(Mandatory = $true)]
    [ValidateRange(300, 3000)]
    [int]$MaxGraphicsClockMHz,

    [Parameter(Mandatory = $true)]
    [ValidateRange(50, 1000)]
    [int]$PowerLimitWatts,

    [string]$LogPath = (Join-Path $env:ProgramData 'CAGpuLimits\gpu-limits.log'),

    [string]$StatePath = (Join-Path $env:ProgramData 'CAGpuLimits\gpu-limits-state.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$nvidiaSmi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
$logDirectory = Split-Path -Parent $LogPath
$stateDirectory = Split-Path -Parent $StatePath
New-Item -ItemType Directory -Force -Path $logDirectory, $stateDirectory | Out-Null

function Write-GpuLog {
    param([string]$Message)
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ("{0}`t{1}" -f [DateTime]::UtcNow.ToString('o'), $Message)
}

function Invoke-NvidiaSmi {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& $nvidiaSmi @Arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    Write-GpuLog ("nvidia-smi {0} => exit {1}; {2}" -f ($Arguments -join ' '), $exitCode, ($output -replace "`r?`n", ' | '))
    if ($exitCode -ne 0) {
        throw "nvidia-smi failed with exit code ${exitCode}: $output"
    }
    return $output
}

if (-not (Test-Path -LiteralPath $nvidiaSmi -PathType Leaf)) {
    throw "nvidia-smi was not found: $nvidiaSmi"
}

$gpuIndexValues = @()
foreach ($token in @($GpuIndexList -split ',')) {
    $parsedIndex = 0
    if ([string]::IsNullOrWhiteSpace($token) -or -not [int]::TryParse($token.Trim(), [ref]$parsedIndex)) {
        throw "Invalid GPU index list '$GpuIndexList'. Use a comma-separated list such as 0,1."
    }
    $gpuIndexValues += $parsedIndex
}
if (@($gpuIndexValues | Where-Object { $_ -lt 0 }).Count -gt 0) {
    throw 'GPU indices must be zero or greater.'
}
if (@($gpuIndexValues | Select-Object -Unique).Count -ne $gpuIndexValues.Count) {
    throw 'GPU indices must not contain duplicates.'
}

$results = @()
$inventoryRows = @()
$modifiedRows = @()
try {
    # Preflight every target before changing any card. This prevents an invalid
    # later index or out-of-range power request from leaving an earlier GPU changed.
    foreach ($index in $gpuIndexValues) {
        $inventory = Invoke-NvidiaSmi -Arguments @(
            '-i', [string]$index,
            '--query-gpu=index,name,power.min_limit,power.max_limit,power.limit',
            '--format=csv,noheader,nounits'
        )
        $parts = @($inventory -split ',' | ForEach-Object { $_.Trim() })
        if ($parts.Count -lt 5 -or [int]$parts[0] -ne $index) {
            throw "Could not validate GPU index $index from nvidia-smi output: $inventory"
        }
        $minimumPower = [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture)
        $maximumPower = [double]::Parse($parts[3], [Globalization.CultureInfo]::InvariantCulture)
        $originalPower = [double]::Parse($parts[4], [Globalization.CultureInfo]::InvariantCulture)
        if ($PowerLimitWatts -lt $minimumPower -or $PowerLimitWatts -gt $maximumPower) {
            throw "Requested ${PowerLimitWatts}W is outside GPU $index range ${minimumPower}-${maximumPower}W."
        }

        $inventoryRows += [pscustomobject]@{
            Index         = $index
            Name          = $parts[1]
            MinimumPower  = $minimumPower
            MaximumPower  = $maximumPower
            OriginalPower = $originalPower
        }
    }

    foreach ($row in $inventoryRows) {
        $index = [int]$row.Index
        $change = [pscustomobject]@{
            Index         = $index
            OriginalPower = [double]$row.OriginalPower
            PowerChanged  = $false
            ClockChanged  = $false
        }
        $modifiedRows += $change
        $powerOutput = Invoke-NvidiaSmi -Arguments @('-i', [string]$index, '-pl', [string]$PowerLimitWatts)
        $change.PowerChanged = $true
        $clockOutput = Invoke-NvidiaSmi -Arguments @('-i', [string]$index, '-lgc', "0,$MaxGraphicsClockMHz")
        $change.ClockChanged = $true
        $verify = Invoke-NvidiaSmi -Arguments @(
            '-i', [string]$index,
            '--query-gpu=index,name,power.limit,clocks.gr',
            '--format=csv,noheader,nounits'
        )
        $verifyParts = @($verify -split ',' | ForEach-Object { $_.Trim() })
        $actualPower = [double]::Parse($verifyParts[2], [Globalization.CultureInfo]::InvariantCulture)
        if ([Math]::Abs($actualPower - $PowerLimitWatts) -gt 0.5) {
            throw "GPU $index power verification failed: expected ${PowerLimitWatts}W, got ${actualPower}W."
        }
        $results += [ordered]@{
            index               = $index
            name                = $row.Name
            maxGraphicsClockMHz = $MaxGraphicsClockMHz
            powerLimitWatts     = $actualPower
            currentClockMHz     = [double]::Parse($verifyParts[3], [Globalization.CultureInfo]::InvariantCulture)
            clockCommandOutput  = $clockOutput
            powerCommandOutput  = $powerOutput
        }
    }

    $state = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status       = 'applied'
        computer     = $env:COMPUTERNAME
        results      = $results
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    Write-GpuLog 'All requested GPU limits were applied and power limits were verified.'
    $state | ConvertTo-Json -Depth 6
    exit 0
}
catch {
    $failure = $_.Exception.Message
    $rollback = @()
    foreach ($change in @($modifiedRows | Sort-Object Index -Descending)) {
        if ($change.ClockChanged) {
            try {
                Invoke-NvidiaSmi -Arguments @('-i', [string]$change.Index, '-rgc') | Out-Null
                $rollback += "GPU $($change.Index) graphics clock lock reset"
            }
            catch {
                $rollback += "GPU $($change.Index) graphics clock rollback failed: $($_.Exception.Message)"
            }
        }
        if ($change.PowerChanged) {
            try {
                Invoke-NvidiaSmi -Arguments @(
                    '-i', [string]$change.Index,
                    '-pl', ([double]$change.OriginalPower).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
                ) | Out-Null
                $rollback += "GPU $($change.Index) power restored to $($change.OriginalPower)W"
            }
            catch {
                $rollback += "GPU $($change.Index) power rollback failed: $($_.Exception.Message)"
            }
        }
    }
    $state = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status       = 'failed'
        computer     = $env:COMPUTERNAME
        message      = $failure
        rollback     = $rollback
        results      = $results
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    Write-GpuLog ("FAILED: {0}; rollback: {1}" -f $failure, ($rollback -join ' | '))
    Write-Error $failure
    exit 1
}
