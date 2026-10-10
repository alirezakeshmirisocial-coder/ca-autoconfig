Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CALlamaBenchPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { throw "llama-bench JSON is missing '$Name'." }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "llama-bench JSON is missing '$Name'." }
    return $property.Value
}

function ConvertTo-CALlamaBenchFiniteNumber {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$AllowZero
    )

    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number) -or
        ($AllowZero -and $number -lt 0) -or (-not $AllowZero -and $number -le 0)) {
        $expectation = if ($AllowZero) { 'a non-negative finite number' } else { 'a positive finite number' }
        throw "llama-bench '$Name' must be $expectation."
    }
    return $number
}

function ConvertTo-CALlamaBenchInteger {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $number = 0
    if (-not [int]::TryParse([string]$Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -lt 0) {
        throw "llama-bench '$Name' must be a non-negative integer."
    }
    return $number
}

function Assert-CALlamaBenchSamples {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][int]$Repetitions,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $samples = @(Get-CALlamaBenchPropertyValue -Object $Row -Name 'samples_ts')
    if ($samples.Count -ne $Repetitions) {
        throw "llama-bench $Kind row contains $($samples.Count) samples; expected $Repetitions."
    }
    foreach ($sample in $samples) {
        ConvertTo-CALlamaBenchFiniteNumber -Value $sample -Name "$Kind.samples_ts[]" | Out-Null
    }
}

function ConvertFrom-CALlamaBenchJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Json,
        [Parameter(Mandatory = $true)][ValidateRange(1, 1048576)][int]$PromptTokens,
        [Parameter(Mandatory = $true)][ValidateRange(1, 1048576)][int]$GenerationTokens,
        [Parameter(Mandatory = $true)][ValidateRange(1, 1000)][int]$Repetitions
    )

    try {
        $document = $Json | ConvertFrom-Json
        $rows = @($document | ForEach-Object { $_ })
    }
    catch { throw 'llama-bench did not return valid JSON.' }
    if ($rows.Count -ne 2) {
        throw "llama-bench must return exactly one prompt-processing row and one generation row; received $($rows.Count)."
    }

    $promptRows = @($rows | Where-Object {
        (ConvertTo-CALlamaBenchInteger (Get-CALlamaBenchPropertyValue $_ 'n_prompt') 'n_prompt') -eq $PromptTokens -and
        (ConvertTo-CALlamaBenchInteger (Get-CALlamaBenchPropertyValue $_ 'n_gen') 'n_gen') -eq 0
    })
    $generationRows = @($rows | Where-Object {
        (ConvertTo-CALlamaBenchInteger (Get-CALlamaBenchPropertyValue $_ 'n_prompt') 'n_prompt') -eq 0 -and
        (ConvertTo-CALlamaBenchInteger (Get-CALlamaBenchPropertyValue $_ 'n_gen') 'n_gen') -eq $GenerationTokens
    })
    if ($promptRows.Count -ne 1 -or $generationRows.Count -ne 1) {
        throw 'llama-bench JSON does not contain the exact requested pp and tg rows.'
    }

    $promptRow = $promptRows[0]
    $generationRow = $generationRows[0]
    Assert-CALlamaBenchSamples -Row $promptRow -Repetitions $Repetitions -Kind 'pp'
    Assert-CALlamaBenchSamples -Row $generationRow -Repetitions $Repetitions -Kind 'tg'

    $promptRate = ConvertTo-CALlamaBenchFiniteNumber (Get-CALlamaBenchPropertyValue $promptRow 'avg_ts') 'pp.avg_ts'
    $generationRate = ConvertTo-CALlamaBenchFiniteNumber (Get-CALlamaBenchPropertyValue $generationRow 'avg_ts') 'tg.avg_ts'

    $promptCommit = ([string](Get-CALlamaBenchPropertyValue $promptRow 'build_commit')).Trim()
    $generationCommit = ([string](Get-CALlamaBenchPropertyValue $generationRow 'build_commit')).Trim()
    if ($promptCommit -ne $generationCommit -or $promptCommit -notmatch '^[A-Za-z0-9._-]{1,64}$') {
        throw 'llama-bench build identity is missing, inconsistent, or unsafe to export.'
    }
    $promptBackends = ([string](Get-CALlamaBenchPropertyValue $promptRow 'backends')).Trim()
    $generationBackends = ([string](Get-CALlamaBenchPropertyValue $generationRow 'backends')).Trim()
    if ($promptBackends -ne $generationBackends -or $promptBackends -notmatch '^[A-Za-z0-9 .,+_-]{1,96}$') {
        throw 'llama-bench backend identity is missing, inconsistent, or unsafe to export.'
    }

    [pscustomobject][ordered]@{
        PromptTokensPerSecond     = $promptRate
        GenerationTokensPerSecond = $generationRate
        Backend                   = "llama.cpp $promptCommit · $promptBackends"
        BuildCommit               = $promptCommit
        Backends                  = $promptBackends
    }
}

Export-ModuleMember -Function 'ConvertFrom-CALlamaBenchJson'
