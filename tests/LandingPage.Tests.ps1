$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$htmlPath = Join-Path $root 'docs\index.html'
$cssPath = Join-Path $root 'docs\site.css'
$imagePath = Join-Path $root 'docs\assets\hud-alpha.png'
$socialPreviewPath = Join-Path $root 'docs\assets\social-preview.png'
$socialPreviewSourcePath = Join-Path $root 'docs\assets\social-preview.svg'
$noJekyllPath = Join-Path $root 'docs\.nojekyll'
$html = Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
$css = Get-Content -LiteralPath $cssPath -Raw -Encoding UTF8
$socialPreviewSource = Get-Content -LiteralPath $socialPreviewSourcePath -Raw -Encoding UTF8

function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }

Assert-True (Test-Path -LiteralPath $imagePath -PathType Leaf) 'Landing-page HUD image is missing.'
Assert-True (Test-Path -LiteralPath $socialPreviewPath -PathType Leaf) 'Social-preview PNG is missing.'
Assert-True (Test-Path -LiteralPath $socialPreviewSourcePath -PathType Leaf) 'Social-preview SVG source is missing.'
Assert-True (Test-Path -LiteralPath $noJekyllPath -PathType Leaf) 'The static Pages opt-out file is missing.'
Assert-True ($html -match '<meta name="viewport"') 'Responsive viewport metadata is missing.'
Assert-True ($html -match '<meta http-equiv="Content-Security-Policy"') 'Static Content Security Policy is missing.'
Assert-True ($html -match '<a class="skip-link" href="#main">') 'Keyboard skip link is missing.'
Assert-True ($html -match '<main id="main">' -and $html -match '<nav aria-label="Primary navigation">') 'Page landmarks are incomplete.'
Assert-True ($html -match 'alt="CA AutoConfig HUD with a small lock control') 'HUD image does not have useful alternative text.'
Assert-True ($html -match 'assets/social-preview\.png' -and $html -match 'og:image:width" content="1280"' -and $html -match 'og:image:height" content="640"') 'Open Graph preview path or dimensions are missing.'
Assert-True ($html -match 'blob/main/docs/QUICKSTART\.md' -and $html -match 'Try the portable HUD' -and $html -match 'Open the two-minute quick start') 'Portable quick-start calls to action are missing.'
$portableHtmlIndex = $html.IndexOf('.\CAAutoConfig.exe', [StringComparison]::Ordinal)
$installHtmlIndex = $html.IndexOf('.\Install-DesktopApp.ps1', [StringComparison]::Ordinal)
Assert-True ($portableHtmlIndex -ge 0 -and $portableHtmlIndex -lt $installHtmlIndex -and $html -match '(?i)without creating a task or shortcut' -and $html -match '(?i)install startup only after') 'Homepage does not preserve portable-trial-before-optional-install ordering.'
Assert-True ($socialPreviewSource -match '<svg[^>]+width="1280"[^>]+height="640"' -and $socialPreviewSource -match '<title' -and $socialPreviewSource -match '<desc') 'Social-preview source is missing dimensions or accessible text.'
Assert-True ($socialPreviewSource -notmatch '(?i)<script|(?:xlink:)?href="https?://') 'Social-preview source contains script or a remote runtime asset.'
Assert-True ($html -match 'v0\.2\.6-alpha\.4' -and $html -match 'Unsigned pre-release') 'Release link or alpha boundary is missing.'
Assert-True ($html -match 'v0\.2\.5-alpha\.2' -and $html -match 'not a universal footprint promise') 'Measured-evidence version boundary is missing.'
Assert-True ($html -match 'docs/evidence/hud-overhead-120s-2026-10-10\.json') 'Raw overhead evidence is not linked.'
Assert-True ($html -match 'template=display-result\.yml') 'Focused external evidence intake is not linked.'
Assert-True ($html -match 'no scripts, cookies, analytics or third-party fonts') 'No-tracking statement is missing.'
Assert-True ($html -notmatch '<script|googletagmanager|google-analytics|plausible|posthog|segment\.com|fonts\.googleapis|fonts\.gstatic') 'Landing page contains a script, tracker, or third-party font.'
Assert-True ($html -notmatch 'target="_blank"') 'Landing page opens unrequested new tabs.'
Assert-True ($css -match ':focus-visible' -and $css -match 'prefers-reduced-motion') 'Keyboard focus or reduced-motion handling is missing.'
Assert-True ($css -notmatch '(?i)@import|url\(\s*["'']?https?://') 'Stylesheet loads an external resource.'
Assert-True ($css -notmatch '(?i)animation\s*:') 'Landing page adds nonessential automatic animation.'

Add-Type -AssemblyName System.Drawing
$preview = [Drawing.Image]::FromFile($socialPreviewPath)
try {
    Assert-True ($preview.Width -eq 1280 -and $preview.Height -eq 640) 'Social-preview PNG is not exactly 1280 by 640 pixels.'
}
finally {
    $preview.Dispose()
}
Assert-True ((Get-Item -LiteralPath $socialPreviewPath).Length -lt 1MB) 'Social-preview PNG exceeds GitHub''s one-megabyte limit.'

Write-Host '26 landing-page tests passed. The static site and social preview have no scripts, analytics, external fonts, or application-side network client.' -ForegroundColor Cyan
