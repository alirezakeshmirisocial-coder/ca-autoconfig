$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$htmlPath = Join-Path $root 'docs\index.html'
$cssPath = Join-Path $root 'docs\site.css'
$imagePath = Join-Path $root 'docs\assets\hud-alpha.png'
$noJekyllPath = Join-Path $root 'docs\.nojekyll'
$html = Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
$css = Get-Content -LiteralPath $cssPath -Raw -Encoding UTF8

function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }

Assert-True (Test-Path -LiteralPath $imagePath -PathType Leaf) 'Landing-page HUD image is missing.'
Assert-True (Test-Path -LiteralPath $noJekyllPath -PathType Leaf) 'The static Pages opt-out file is missing.'
Assert-True ($html -match '<meta name="viewport"') 'Responsive viewport metadata is missing.'
Assert-True ($html -match '<meta http-equiv="Content-Security-Policy"') 'Static Content Security Policy is missing.'
Assert-True ($html -match '<a class="skip-link" href="#main">') 'Keyboard skip link is missing.'
Assert-True ($html -match '<main id="main">' -and $html -match '<nav aria-label="Primary navigation">') 'Page landmarks are incomplete.'
Assert-True ($html -match 'alt="CA AutoConfig HUD with a small lock control') 'HUD image does not have useful alternative text.'
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

Write-Host '16 landing-page tests passed. The static site has no scripts, analytics, external fonts, or application-side network client.' -ForegroundColor Cyan
