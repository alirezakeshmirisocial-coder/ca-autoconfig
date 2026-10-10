[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Model,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Prompt,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
    [string]$BenchmarkId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GpuIndexList,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [uri]$OllamaBaseUri = 'http://127.0.0.1:11434',

    [ValidateRange(32, 32768)]
    [int]$NumPredict = 512,

    [ValidateRange(512, 131072)]
    [int]$NumCtx = 4096,

    [ValidateRange(1, 128)]
    [int]$WarmupNumPredict = 16,

    [ValidateRange(250, 5000)]
    [int]$IntervalMilliseconds = 500,

    [ValidateRange(1, 3600)]
    [int]$MinimumMeasuredSeconds = 10,

    [ValidateRange(10, 7200)]
    [int]$TimeoutSeconds = 900,

    [ValidateRange(1, 1000)]
    [int]$Repetition = 1,

    [ValidateNotNullOrEmpty()]
    [string]$KeepAlive = '10m',

    [string]$NvidiaSmiPath = (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),

    [switch]$AllowRemoteEndpoint,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PowerCurve.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'OllamaAdapter.psm1') -Force
Add-Type -AssemblyName System.Net.Http

if (-not [Net.IPAddress]::IsLoopback(([Net.Dns]::GetHostAddresses($OllamaBaseUri.DnsSafeHost) | Select-Object -First 1)) -and -not $AllowRemoteEndpoint) {
    throw 'The Ollama endpoint is not loopback. Refusing to send the prompt unless -AllowRemoteEndpoint is explicit.'
}
if ($OllamaBaseUri.Scheme -notin @('http', 'https')) { throw 'OllamaBaseUri must use http or https.' }
if (-not (Test-Path -LiteralPath $NvidiaSmiPath -PathType Leaf)) { throw "nvidia-smi was not found: $NvidiaSmiPath" }
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) { throw "Output already exists: $OutputPath. Use -Force to replace it." }

$gpuIndexes = @()
foreach ($token in @($GpuIndexList -split ',')) {
    $index = 0
    if ([string]::IsNullOrWhiteSpace($token) -or -not [int]::TryParse($token.Trim(), [ref]$index) -or $index -lt 0) {
        throw "Invalid GPU index list '$GpuIndexList'. Use a comma-separated list such as 0,1."
    }
    $gpuIndexes += $index
}
if (@($gpuIndexes | Select-Object -Unique).Count -ne $gpuIndexes.Count) { throw 'GPU indices must not contain duplicates.' }

function ConvertTo-NullableDouble {
    param($Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or $text -match '^(N/A|\[N/A\]|Not Supported)$') { return $null }
    $number = 0.0
    if (-not [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
    return $number
}

function Read-GpuTelemetry {
    param([Parameter(Mandatory = $true)][int]$Index)
    $arguments = @(
        '-i', [string]$Index,
        '--query-gpu=index,name,driver_version,power.limit,power.draw,temperature.gpu,utilization.gpu,memory.used,memory.total,clocks.gr',
        '--format=csv,noheader,nounits'
    )
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& $NvidiaSmiPath @arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    if ($exitCode -ne 0) { throw "nvidia-smi telemetry query for GPU $Index failed with exit code ${exitCode}: $output" }
    $rows = @($output | ConvertFrom-Csv -Header @('Index', 'Name', 'Driver', 'PowerLimit', 'PowerDraw', 'Temperature', 'Utilization', 'MemoryUsed', 'MemoryTotal', 'Clock'))
    if ($rows.Count -ne 1 -or [int]$rows[0].Index -ne $Index) { throw "Unexpected nvidia-smi response for GPU ${Index}: $output" }
    return $rows[0]
}

function New-JsonContent {
    param([Parameter(Mandatory = $true)]$Body)
    $json = $Body | ConvertTo-Json -Depth 8 -Compress
    return [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
}

function Read-JsonResponse {
    param([Parameter(Mandatory = $true)][Net.Http.HttpResponseMessage]$Response, [Parameter(Mandatory = $true)][string]$Operation)
    if (-not $Response.IsSuccessStatusCode) { throw "Ollama $Operation failed with HTTP $([int]$Response.StatusCode)." }
    $text = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ([string]::IsNullOrWhiteSpace($text)) { throw "Ollama $Operation returned an empty response." }
    return $text | ConvertFrom-Json
}

function Invoke-OllamaPost {
    param([Parameter(Mandatory = $true)][Net.Http.HttpClient]$Client, [Parameter(Mandatory = $true)][uri]$Uri, [Parameter(Mandatory = $true)]$Body, [Parameter(Mandatory = $true)][string]$Operation)
    $content = New-JsonContent -Body $Body
    try {
        $response = $Client.PostAsync($Uri, $content).GetAwaiter().GetResult()
        try { return Read-JsonResponse -Response $response -Operation $Operation }
        finally { $response.Dispose() }
    }
    finally { $content.Dispose() }
}

$base = $OllamaBaseUri.AbsoluteUri.TrimEnd('/')
$httpHandler = [Net.Http.HttpClientHandler]::new()
$httpHandler.AllowAutoRedirect = $false
$client = [Net.Http.HttpClient]::new($httpHandler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
try {
    $versionResponse = $client.GetAsync("$base/api/version").GetAwaiter().GetResult()
    try { $versionDocument = Read-JsonResponse -Response $versionResponse -Operation 'version query' }
    finally { $versionResponse.Dispose() }
    $versionProperty = $versionDocument.PSObject.Properties['version']
    $ollamaVersion = if ($null -eq $versionProperty -or [string]::IsNullOrWhiteSpace([string]$versionProperty.Value)) { 'unknown' } else { [string]$versionProperty.Value }

    try {
        $showDocument = Invoke-OllamaPost -Client $client -Uri ([uri]"$base/api/show") -Operation 'model query' -Body ([ordered]@{ model = $Model; verbose = $false })
    }
    catch {
        throw "Ollama model '$Model' is unavailable at the selected endpoint. Install it explicitly first; this adapter never pulls models."
    }
    $quantization = ''
    $detailsProperty = $showDocument.PSObject.Properties['details']
    if ($null -ne $detailsProperty -and $null -ne $detailsProperty.Value) {
        $quantizationProperty = $detailsProperty.Value.PSObject.Properties['quantization_level']
        if ($null -ne $quantizationProperty) { $quantization = [string]$quantizationProperty.Value }
    }

    $warmupBody = [ordered]@{
        model      = $Model
        prompt     = 'Reply with OK.'
        stream     = $false
        think      = $false
        keep_alive = $KeepAlive
        options    = [ordered]@{ temperature = 0; seed = 42; num_ctx = $NumCtx; num_predict = $WarmupNumPredict }
    }
    $warmupClock = [Diagnostics.Stopwatch]::StartNew()
    $warmupDocument = Invoke-OllamaPost -Client $client -Uri ([uri]"$base/api/generate") -Operation 'warm-up' -Body $warmupBody
    $warmupClock.Stop()
    $warmupDone = $warmupDocument.PSObject.Properties['done']
    if ($null -eq $warmupDone -or -not [bool]$warmupDone.Value) { throw 'Ollama warm-up did not complete.' }

    $gpuData = [ordered]@{}
    foreach ($index in $gpuIndexes) {
        $inventory = Read-GpuTelemetry -Index $index
        $gpuData[[string]$index] = [ordered]@{
            index           = $index
            model           = ([string]$inventory.Name).Trim()
            driver          = ([string]$inventory.Driver).Trim()
            powerLimitWatts = ConvertTo-NullableDouble $inventory.PowerLimit
            samples         = New-Object Collections.Generic.List[object]
        }
    }

    $measureBody = [ordered]@{
        model      = $Model
        prompt     = $Prompt
        stream     = $false
        think      = $false
        keep_alive = $KeepAlive
        options    = [ordered]@{ temperature = 0; seed = 42; num_ctx = $NumCtx; num_predict = $NumPredict }
    }
    $measureContent = New-JsonContent -Body $measureBody
    $measureClock = [Diagnostics.Stopwatch]::StartNew()
    $measureTask = $client.PostAsync([uri]"$base/api/generate", $measureContent)
    $sampleIndex = 0
    $measureFailure = $null
    $measureDocument = $null
    try {
        do {
            foreach ($index in $gpuIndexes) {
                $row = Read-GpuTelemetry -Index $index
                $gpuData[[string]$index].samples.Add([pscustomobject][ordered]@{
                    elapsedMilliseconds = [int][Math]::Round($measureClock.Elapsed.TotalMilliseconds)
                    powerDrawWatts      = ConvertTo-NullableDouble $row.PowerDraw
                    temperatureC        = ConvertTo-NullableDouble $row.Temperature
                    utilizationPercent  = ConvertTo-NullableDouble $row.Utilization
                    memoryUsedMiB       = ConvertTo-NullableDouble $row.MemoryUsed
                    memoryTotalMiB      = ConvertTo-NullableDouble $row.MemoryTotal
                    graphicsClockMHz    = ConvertTo-NullableDouble $row.Clock
                })
            }
            if ($measureTask.IsCompleted) { break }
            $sampleIndex++
            $nextTarget = $sampleIndex * $IntervalMilliseconds
            $remaining = $nextTarget - [int][Math]::Round($measureClock.Elapsed.TotalMilliseconds)
            if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
        } while (-not $measureTask.IsCompleted)

        try {
            $measureResponse = $measureTask.GetAwaiter().GetResult()
            try { $measureDocument = Read-JsonResponse -Response $measureResponse -Operation 'measured generation' }
            finally { $measureResponse.Dispose() }
        }
        catch {
            $measureFailure = 'The measured Ollama request failed or returned an invalid HTTP response.'
        }
    }
    finally {
        $measureClock.Stop()
        $measureContent.Dispose()
    }

    $measuredSeconds = $measureClock.Elapsed.TotalSeconds
    $promptTokensPerSecond = $null
    $generationTokensPerSecond = $null
    if ($null -eq $measureFailure) {
        try {
            $throughput = ConvertFrom-CAOllamaGenerateResponse -Response $measureDocument
            $promptTokensPerSecond = $throughput.PromptTokensPerSecond
            $generationTokensPerSecond = $throughput.GenerationTokensPerSecond
        }
        catch {
            $measureFailure = 'The measured Ollama response did not contain valid throughput evidence.'
        }
    }
    if ($null -ne $measureFailure) {
        $resultStatus = 'failed'
        $resultError = $measureFailure
    }
    elseif ($measuredSeconds -lt $MinimumMeasuredSeconds) {
        $resultStatus = 'incomplete'
        $resultError = 'Measured generation ended before the configured minimum steady window; increase -NumPredict or adjust the prompt.'
    }
    else {
        $resultStatus = 'passed'
        $resultError = $null
    }

    $gpus = foreach ($index in $gpuIndexes) {
        $gpu = $gpuData[[string]$index]
        [pscustomobject][ordered]@{
            index           = $gpu.index
            model           = $gpu.model
            driver          = $gpu.driver
            powerLimitWatts = $gpu.powerLimitWatts
            samples         = $gpu.samples.ToArray()
        }
    }

    $run = [pscustomobject][ordered]@{
        schemaVersion = 1
        runId         = 'run-' + [Guid]::NewGuid().ToString('N')
        createdUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        source        = 'live'
        privacy       = [pscustomobject][ordered]@{
            containsGpuUuid     = $false
            containsMachineName = $false
            containsUserName    = $false
            containsPaths       = $false
            containsRawCommand  = $false
        }
        workload      = [pscustomobject][ordered]@{
            class        = 'ollama'
            name         = "$BenchmarkId · Ollama generate · num_ctx=$NumCtx · num_predict=$NumPredict · temperature=0 · seed=42"
            model        = $Model
            quantization = $quantization
            backend      = "Ollama $ollamaVersion local API"
        }
        protocol      = [pscustomobject][ordered]@{
            warmupSeconds        = [int][Math]::Ceiling($warmupClock.Elapsed.TotalSeconds)
            sampleSeconds        = [int][Math]::Max(1, [Math]::Ceiling($measuredSeconds))
            intervalMilliseconds = $IntervalMilliseconds
            repetition           = $Repetition
        }
        result        = [pscustomobject][ordered]@{
            status     = $resultStatus
            throughput = [pscustomobject][ordered]@{
                promptTokensPerSecond     = $promptTokensPerSecond
                generationTokensPerSecond = $generationTokensPerSecond
            }
            error      = $resultError
        }
        gpus          = @($gpus)
    }

    Assert-CAPowerCurveRun -Run $run | Out-Null
    $fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $fullOutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }
    $run | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $fullOutputPath -Encoding UTF8

    [pscustomobject]@{
        Status                     = if ($resultStatus -eq 'passed') { 'Recorded' } elseif ($resultStatus -eq 'incomplete') { 'RecordedIncomplete' } else { 'RecordedFailed' }
        Output                     = $fullOutputPath
        RunId                      = $run.runId
        Model                      = $Model
        Quantization               = $quantization
        PromptTokensPerSecond      = $promptTokensPerSecond
        GenerationTokensPerSecond  = $generationTokensPerSecond
        MeasuredSeconds            = [Math]::Round($measuredSeconds, 3)
        SamplesPerGpu              = @($gpus[0].samples).Count
        HardwareWrites             = $false
        ContainsPromptOrResponse   = $false
    }
}
finally { $client.Dispose() }
