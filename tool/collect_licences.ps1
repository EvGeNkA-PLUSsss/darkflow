#Requires -Version 5.1
<#
.SYNOPSIS
    Copies the licence text of every bundled Dart package into licenses/.

.DESCRIPTION
    A published application has to carry the notices of the software it
    redistributes. The Dart packages DarkFlow links are MIT, BSD and Apache-2.0,
    all of which require the notice to travel with the binary.

    The texts are read from the pub cache, so they match the versions
    `pubspec.lock` actually resolved rather than whatever was current when
    somebody last copied a file by hand. Re-run this after a dependency bump.

    The Tor and pluggable-transport notices are not handled here: those binaries
    are fetched and verified by tool/fetch_tor_windows.ps1, which records their
    source and placeholders for their texts.

.PARAMETER Force
    Overwrite files that already exist. Without it, an existing file is left alone
    and reported, so a hand-edited notice is never silently replaced.

.EXAMPLE
    pwsh -File tool/collect_licences.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root 'licenses\flutter-libraries'

# The packages named on the About screen, plus the ones that carry an obligation
# of their own. Kept in step with `AboutScreen._components` by hand, because the
# alternative - parsing Dart - would be more fragile than the list.
$packages = @(
    'cryptography',
    'pretty_qr_code',
    'record',
    'audioplayers',
    'file_picker',
    'mobile_scanner',
    'path_provider',
    'intl',
    'mime',
    'ffi'
)

$cache = Join-Path $env:LOCALAPPDATA 'Pub\Cache\hosted\pub.dev'
if (-not (Test-Path -LiteralPath $cache)) {
    throw "The pub cache was not found at $cache. Run 'flutter pub get' first."
}

# The version each package is actually *resolved* to, read from pubspec.lock.
#
# Taking the newest match in the pub cache instead is wrong, and was: `intl` is
# pinned to exactly 0.20.2 by flutter_localizations while 0.20.3 sits in the cache,
# so the newest-match version copied the licence of a package that is not in the
# build. Shipping the wrong notice is worse than shipping none, because it reads as
# a claim.
$lockPath = Join-Path $root 'pubspec.lock'
if (-not (Test-Path -LiteralPath $lockPath)) {
    throw "pubspec.lock is missing; run 'flutter pub get' before collecting licences."
}
$lock = Get-Content -LiteralPath $lockPath -Raw

function Get-ResolvedVersion([string]$package) {
    $pattern = "(?m)^  $([regex]::Escape($package)):\r?\n(?:.*\r?\n)*?    version:\s*`"([^`"]+)`""
    $match = [regex]::Match($lock, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

New-Item -ItemType Directory -Force -Path $target | Out-Null

$copied = 0
$kept = 0
$missing = @()

foreach ($package in $packages) {
    $version = Get-ResolvedVersion $package
    if ($null -eq $version) {
        $missing += "$package (not in pubspec.lock)"
        continue
    }

    $directory = Join-Path $cache "$package-$version"
    if (-not (Test-Path -LiteralPath $directory)) {
        $missing += "$package-$version (absent from the pub cache)"
        continue
    }

    $licence = Get-ChildItem -LiteralPath $directory -File |
        Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING)' } |
        Select-Object -First 1
    if ($null -eq $licence) {
        $missing += "$package-$version (no licence file)"
        continue
    }

    $destination = Join-Path $target "$package-$version.txt"
    if ((Test-Path -LiteralPath $destination) -and -not $Force) {
        $kept++
        continue
    }
    Copy-Item -LiteralPath $licence.FullName -Destination $destination -Force
    $copied++
}

Write-Host "Copied $copied licence texts into licenses/flutter-libraries ($kept already present)." -ForegroundColor Green
if ($missing.Count -gt 0) {
    Write-Warning ("No licence file found for: " + ($missing -join ', ') +
                   ". Check the package names in this script against pubspec.yaml.")
    exit 1
}
