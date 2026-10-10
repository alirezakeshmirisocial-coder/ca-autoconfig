Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CAOllamaPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Optional
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        if ($Optional) { return $null }
        throw "Ollama response is missing '$Name'."
    }
    return $Object.PSObject.Properties[$Name].Value
}

function ConvertTo-CAOllamaFiniteNumber {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$AllowZero
    )

    $number = 0.0
    if ($null -eq $Value -or
        -not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number) -or
        $(if ($AllowZero) { $number -lt 0 } else { $number -le 0 })) {
        $expectation = if ($AllowZero) { 'a non-negative finite number' } else { 'a positive finite number' }
        throw "Ollama response '$Name' must be $expectation."
    }
    return $number
}

function ConvertFrom-CAOllamaGenerateResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Response)

    $done = Get-CAOllamaPropertyValue -Object $Response -Name 'done'
    if (-not [bool]$done) { throw 'Ollama generation did not report done=true.' }

    $promptCount = ConvertTo-CAOllamaFiniteNumber (Get-CAOllamaPropertyValue -Object $Response -Name 'prompt_eval_count') 'prompt_eval_count' -AllowZero
    $promptDuration = ConvertTo-CAOllamaFiniteNumber (Get-CAOllamaPropertyValue -Object $Response -Name 'prompt_eval_duration') 'prompt_eval_duration' -AllowZero
    $cachedValue = Get-CAOllamaPropertyValue -Object $Response -Name 'prompt_eval_cached_count' -Optional
    $cachedCount = if ($null -eq $cachedValue) { 0.0 } else { ConvertTo-CAOllamaFiniteNumber $cachedValue 'prompt_eval_cached_count' -AllowZero }
    if ($cachedCount -gt $promptCount) { throw 'Ollama cached prompt count exceeds total prompt count.' }

    $generationCount = ConvertTo-CAOllamaFiniteNumber (Get-CAOllamaPropertyValue -Object $Response -Name 'eval_count') 'eval_count' -AllowZero
    $generationDuration = ConvertTo-CAOllamaFiniteNumber (Get-CAOllamaPropertyValue -Object $Response -Name 'eval_duration') 'eval_duration' -AllowZero

    $uncachedPromptCount = $promptCount - $cachedCount
    $promptTokensPerSecond = $null
    if ($uncachedPromptCount -gt 0) {
        if ($promptDuration -le 0) { throw 'Ollama reported uncached prompt tokens without prompt_eval_duration.' }
        $promptTokensPerSecond = [Math]::Round($uncachedPromptCount / ($promptDuration / 1000000000.0), 6)
    }

    $generationTokensPerSecond = $null
    if ($generationCount -gt 0) {
        if ($generationDuration -le 0) { throw 'Ollama reported generated tokens without eval_duration.' }
        $generationTokensPerSecond = [Math]::Round($generationCount / ($generationDuration / 1000000000.0), 6)
    }

    if ($null -eq $promptTokensPerSecond -and $null -eq $generationTokensPerSecond) {
        throw 'Ollama response contains no measurable uncached prompt or generation throughput.'
    }

    [pscustomobject][ordered]@{
        PromptTokensPerSecond     = $promptTokensPerSecond
        GenerationTokensPerSecond = $generationTokensPerSecond
        PromptTokens              = [int64]$promptCount
        CachedPromptTokens        = [int64]$cachedCount
        GenerationTokens          = [int64]$generationCount
    }
}

Export-ModuleMember -Function 'ConvertFrom-CAOllamaGenerateResponse'
