[CmdletBinding()]
param(
    [int[]]$GpuIndices = @(0, 1),

    [ValidateRange(300, 3000)]
    [int]$MaxGraphicsClockMHz = 1700,

    [ValidateRange(50, 1000)]
    [int]$PowerLimitWatts = 280,

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

$results = @()
try {
    foreach ($index in $GpuIndices) {
        $inventory = Invoke-NvidiaSmi -Arguments @(
            '-i', [string]$index,
            '--query-gpu=index,name,power.min_limit,power.max_limit',
            '--format=csv,noheader,nounits'
        )
        $parts = @($inventory -split ',' | ForEach-Object { $_.Trim() })
        if ($parts.Count -lt 4 -or [int]$parts[0] -ne $index) {
            throw "Could not validate GPU index $index from nvidia-smi output: $inventory"
        }
        $minimumPower = [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture)
        $maximumPower = [double]::Parse($parts[3], [Globalization.CultureInfo]::InvariantCulture)
        if ($PowerLimitWatts -lt $minimumPower -or $PowerLimitWatts -gt $maximumPower) {
            throw "Requested ${PowerLimitWatts}W is outside GPU $index range ${minimumPower}-${maximumPower}W."
        }

        $powerOutput = Invoke-NvidiaSmi -Arguments @('-i', [string]$index, '-pl', [string]$PowerLimitWatts)
        $clockOutput = Invoke-NvidiaSmi -Arguments @('-i', [string]$index, '-lgc', "0,$MaxGraphicsClockMHz")
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
            name                = $parts[1]
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
    $state = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        status       = 'failed'
        computer     = $env:COMPUTERNAME
        message      = $_.Exception.Message
        results      = $results
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    Write-GpuLog ("FAILED: {0}" -f $_.Exception.Message)
    Write-Error $_.Exception.Message
    exit 1
}
