[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-UnsafeReport {
    param([Parameter(Mandatory = $true)][string]$Reason)
    throw "Display diagnostics preflight failed: $Reason"
}

$resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
if (-not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
    Stop-UnsafeReport 'input is not a file'
}

$item = Get-Item -LiteralPath $resolved.Path
if ($item.Length -le 0 -or $item.Length -gt 32768) {
    Stop-UnsafeReport 'input size is outside the 1-32768 byte boundary'
}

$raw = Get-Content -LiteralPath $resolved.Path -Raw -Encoding UTF8
$raw = $raw.TrimEnd("`r", "`n")
$lines = @($raw -split "`r?`n")
if ($lines.Count -lt 11 -or $lines.Count -gt 128) {
    Stop-UnsafeReport 'unexpected line count'
}

$forbiddenPatterns = @(
    '(?i)\bGPU-[0-9a-f-]{12,}\b',
    '(?i)\\\\\.\\DISPLAY\d+',
    '(?i)\b(?:PCI|PNP)\\[^\s;]+',
    '(?i)\bS-1-\d+(?:-\d+){2,}\b',
    '(?i)\b[A-Z]:\\',
    '(?i)\\\\[^\\\s]+\\[^\s]+',
    '(?i)^\s*(?:user|username|computer|machine|hostname|serial|uuid|path|command|prompt|workflow)\s*:',
    '(?i)https?://',
    '(?i)\b[\w.%+-]+@[\w.-]+\.[A-Z]{2,}\b'
)
foreach ($pattern in $forbiddenPatterns) {
    if ($raw -match $pattern) {
        Stop-UnsafeReport 'private identifier, path, command, URL, or unsupported field detected'
    }
}

if ($lines[0] -cne 'CA AutoConfig diagnostics (privacy-safe)') {
    Stop-UnsafeReport 'header is missing or altered'
}
if ($lines[1] -notmatch '^App: [A-Za-z0-9][A-Za-z0-9.+ -]{0,79}$') {
    Stop-UnsafeReport 'App line is missing or malformed'
}
if ($lines[2] -notmatch '^Captured UTC: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
    Stop-UnsafeReport 'Captured UTC line is missing or malformed'
}
try { [void][DateTime]::ParseExact($lines[2].Substring(14), 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) }
catch { Stop-UnsafeReport 'Captured UTC value is invalid' }
if ($lines[3] -notmatch '^Windows: [A-Za-z0-9][A-Za-z0-9 .()_-]{0,119} · (?:X64|X86|Arm|Arm64|unknown)$') {
    Stop-UnsafeReport 'Windows line is missing or malformed'
}
if ($lines[4] -notmatch '^Shortcut: (?:[A-Za-z0-9]+(?: \+ [A-Za-z0-9]+)*|unknown)$') {
    Stop-UnsafeReport 'Shortcut line is missing or malformed'
}
if ($lines[5] -notmatch '^Selected display: (?:(?:Display \d+ · \d+x\d+)|disconnected display)$') {
    Stop-UnsafeReport 'Selected display line is missing or malformed'
}
if ($lines[6] -notmatch '^GPU profile: [A-Za-z0-9][A-Za-z0-9 .,+()_\/-]{0,199}$') {
    Stop-UnsafeReport 'GPU profile line is missing or malformed'
}
if ($lines[7] -ne '' -or $lines[8] -cne 'Displays:') {
    Stop-UnsafeReport 'display section boundary is missing or altered'
}

$gpuHeaderIndex = [Array]::IndexOf($lines, 'GPUs:')
if ($gpuHeaderIndex -le 9 -or $gpuHeaderIndex -ge $lines.Count - 2) {
    Stop-UnsafeReport 'GPU section boundary is missing or misplaced'
}
if ($lines[$lines.Count - 1] -cne 'Privacy: excludes usernames, machine names, GPU UUIDs, paths, prompts, outputs, workflows, and image content.') {
    Stop-UnsafeReport 'privacy boundary is missing or altered'
}

$displayPattern = '^- Display (?<index>\d+): (?<width>\d+)x(?<height>\d+) at \((?<x>-?\d+),(?<y>-?\d+)\); (?<scale>\d+%|unknown scale)(?<flags>(?:; (?:primary|selected))*)$'
$displayRows = @()
for ($lineIndex = 9; $lineIndex -lt $gpuHeaderIndex; $lineIndex++) {
    $match = [Regex]::Match($lines[$lineIndex], $displayPattern)
    if (-not $match.Success) {
        Stop-UnsafeReport 'a display topology row is malformed'
    }
    $index = [int]$match.Groups['index'].Value
    $width = [int]$match.Groups['width'].Value
    $height = [int]$match.Groups['height'].Value
    $x = [int]$match.Groups['x'].Value
    $y = [int]$match.Groups['y'].Value
    $scaleText = $match.Groups['scale'].Value
    if ($width -lt 320 -or $width -gt 32768 -or $height -lt 200 -or $height -gt 32768) {
        Stop-UnsafeReport 'a display resolution is outside the accepted boundary'
    }
    $scale = $null
    if ($scaleText -ne 'unknown scale') {
        $scale = [int]$scaleText.TrimEnd('%')
        if ($scale -lt 50 -or $scale -gt 500) {
            Stop-UnsafeReport 'a display scale is outside the accepted boundary'
        }
    }
    $flags = $match.Groups['flags'].Value
    $flagList = @($flags -split '; ' | Where-Object { $_ -ne '' })
    if ($flagList.Count -ne @($flagList | Sort-Object -Unique).Count) {
        Stop-UnsafeReport 'a display topology flag is repeated'
    }
    $displayRows += [pscustomobject]@{
        Index = $index
        Width = $width
        Height = $height
        X = $x
        Y = $y
        Scale = $scale
        Primary = $flagList -contains 'primary'
        Selected = $flagList -contains 'selected'
    }
}

$expectedIndices = @(1..$displayRows.Count)
$actualIndices = @($displayRows | ForEach-Object { $_.Index } | Sort-Object)
if (($actualIndices -join ',') -ne ($expectedIndices -join ',')) {
    Stop-UnsafeReport 'display indices must be unique and consecutive'
}
if (@($displayRows | Where-Object { $_.Primary }).Count -ne 1) {
    Stop-UnsafeReport 'exactly one primary display is required'
}
$selectedRows = @($displayRows | Where-Object { $_.Selected })
$selectedDisconnected = $lines[5] -eq 'Selected display: disconnected display'
if (($selectedDisconnected -and $selectedRows.Count -ne 0) -or (-not $selectedDisconnected -and $selectedRows.Count -ne 1)) {
    Stop-UnsafeReport 'selected-display summary and topology do not agree'
}
if (-not $selectedDisconnected) {
    $selectedSummary = [Regex]::Match($lines[5], '^Selected display: Display (?<index>\d+) · (?<width>\d+)x(?<height>\d+)$')
    $selectedSummaryIndex = [int]$selectedSummary.Groups['index'].Value
    $selectedSummaryWidth = [int]$selectedSummary.Groups['width'].Value
    $selectedSummaryHeight = [int]$selectedSummary.Groups['height'].Value
    if ($selectedRows[0].Index -ne $selectedSummaryIndex -or $selectedRows[0].Width -ne $selectedSummaryWidth -or $selectedRows[0].Height -ne $selectedSummaryHeight) {
        Stop-UnsafeReport 'selected-display summary does not match the selected topology row'
    }
}

$gpuLines = @($lines[($gpuHeaderIndex + 1)..($lines.Count - 2)])
if ($gpuLines.Count -eq 0) {
    Stop-UnsafeReport 'GPU section is empty'
}
if ($gpuLines.Count -eq 1 -and $gpuLines[0] -eq '- None reported') {
    $gpuCount = 0
}
else {
    $gpuCount = 0
    foreach ($gpuLine in $gpuLines) {
        if ($gpuLine -notmatch '^- GPU \d+: [A-Za-z0-9][A-Za-z0-9 .+()_\/-]{0,79}; CUDA/SM (?:\d+%|unknown); VRAM (?:\d+%|unknown); power [^;]{1,80}; vendor range [^;]{1,40}; temperature (?:\d+ C|unknown); clock (?:\d+ MHz|unknown); (?:\d+ W starting point|no starting point)$') {
            Stop-UnsafeReport 'a GPU summary row is malformed or contains unsupported text'
        }
        $gpuCount++
    }
}

$knownScales = @($displayRows | Where-Object { $null -ne $_.Scale } | ForEach-Object { $_.Scale } | Sort-Object -Unique)
[pscustomobject]@{
    SchemaVersion = 1
    Status = 'READY_FOR_DISPLAY_REPORT'
    SafeToAttach = $true
    DisplayCount = $displayRows.Count
    SelectedDisplayIndex = if ($selectedDisconnected) { $null } else { $selectedRows[0].Index }
    DpiScalesPercent = $knownScales
    HasMixedDpi = $knownScales.Count -gt 1
    HasNegativeCoordinates = @($displayRows | Where-Object { $_.X -lt 0 -or $_.Y -lt 0 }).Count -gt 0
    HasVerticalOffset = @($displayRows | Where-Object { $_.Y -ne 0 }).Count -gt 0
    GpuSummaryCount = $gpuCount
    PrivacyBoundaryPresent = $true
    ContentEchoed = $false
    NetworkAccess = $false
    FilesModified = $false
    HardwareAccess = $false
}
