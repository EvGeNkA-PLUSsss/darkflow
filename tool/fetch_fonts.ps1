# Downloads the Inter static TTFs that DarkFlow bundles.
#
# Inter is the typeface the mockups are drawn in (the double-storey `a`, the
# straight-legged `k` and the horizontal terminals on `C` all match), so it is
# shipped with the app rather than relying on whatever the host OS provides.
#
# Usage:  pwsh -File tool/fetch_fonts.ps1 [-Version 4.1]

param(
    [string]$Version = '4.1'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fontDir = Join-Path $root 'assets\fonts'
$temp = Join-Path $env:TEMP "inter-$Version"

if (-not (Test-Path $fontDir)) { New-Item -ItemType Directory -Path $fontDir -Force | Out-Null }

$wanted = @('Regular', 'Medium', 'SemiBold', 'Bold')
$missing = $wanted | Where-Object { -not (Test-Path (Join-Path $fontDir "Inter-$_.ttf")) }
if ($missing.Count -eq 0) {
    Write-Host "All Inter weights already present in $fontDir"
    exit 0
}

$url = "https://github.com/rsms/inter/releases/download/v$Version/Inter-$Version.zip"
Write-Host "Downloading $url"
if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$zip = Join-Path $temp 'inter.zip'
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

Write-Host 'Extracting'
Expand-Archive -Path $zip -DestinationPath $temp -Force

# The archive layout has moved between releases; find the TTFs wherever they are.
$found = Get-ChildItem -Path $temp -Recurse -Filter 'Inter-*.ttf' -File |
    Where-Object { $wanted -contains ($_.BaseName -replace '^Inter-', '') }

if (-not $found) {
    throw "No Inter TTFs found inside $url. Inspect $temp and update this script."
}

foreach ($file in $found) {
    $weight = $file.BaseName -replace '^Inter-', ''
    if ($wanted -notcontains $weight) { continue }
    Copy-Item $file.FullName (Join-Path $fontDir "Inter-$weight.ttf") -Force
    Write-Host ("  Inter-{0}.ttf  ({1:N0} bytes)" -f $weight, $file.Length)
}

Write-Host "Fonts installed into $fontDir"
