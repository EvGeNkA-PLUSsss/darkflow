#Requires -Version 5.1
<#
.SYNOPSIS
    Places the Tor runtime beside a built DarkFlow executable.

.DESCRIPTION
    DarkFlow runs Tor as a child process, so the daemon, its pluggable transports
    and the geoip databases have to exist as real files next to the application.

    They are NOT Flutter assets, and that is the whole reason this script exists.
    Flutter copies every asset directory declared in pubspec.yaml into every build
    on every platform - there is no conditional syntax in pubspec and no Gradle
    exclusion for Flutter assets. A 119 MB Windows runtime declared as an asset
    therefore travelled inside the Android APK, where none of it can execute.
    Leaving it undeclared is not an answer either: an undeclared directory is not
    bundled at all, so the Windows build shipped without a Tor daemon.

    A directory beside the executable has neither problem. `TorBinaryLocator` looks
    there first, and only falls back to bundled assets for a build that predates
    this arrangement.

.PARAMETER Configuration
    Which build output to fill: Debug (default), Release or Profile.

.PARAMETER Platform
    windows (default) or android. Android needs nothing: it runs Tor from jniLibs.

.PARAMETER Clean
    Remove the runtime from the build output instead of placing it.

.EXAMPLE
    pwsh -File tool/stage_tor_runtime.ps1
    Fills build\windows\x64\runner\Debug\tor for `flutter run -d windows`.

.EXAMPLE
    pwsh -File tool/stage_tor_runtime.ps1 -Configuration Release
    Fills the Release output, which is what a distributable build uses.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release', 'Profile')]
    [string]$Configuration = 'Debug',

    [ValidateSet('windows', 'android')]
    [string]$Platform = 'windows',

    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

# Android reads none of this. It ships Tor as jniLibs/arm64-v8a/lib*.so and runs
# it from the read-only native library directory, because the platform forbids
# executing code from app-private storage.
if ($Platform -eq 'android') {
    Write-Host 'Android needs no staging: Tor ships as jniLibs/arm64-v8a/lib*.so.' -ForegroundColor Cyan
    return
}

$runnerOutput = Join-Path $root "build\windows\x64\runner\$Configuration"
$target = Join-Path $runnerOutput 'tor'
$source = Join-Path $root 'tor_runtime\windows'

if ($Clean) {
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
        Write-Host "Removed $target." -ForegroundColor Green
    } else {
        Write-Host 'Nothing staged; the runtime directory is already absent.' -ForegroundColor Cyan
    }
    return
}

if (-not (Test-Path -LiteralPath $runnerOutput)) {
    throw ("The $Configuration build output does not exist: $runnerOutput`n" +
           "Build first (flutter build windows --$($Configuration.ToLower())), then stage.")
}

if (-not (Test-Path -LiteralPath $source)) {
    throw ("The Tor runtime source is missing: $source`n" +
           "Run tool/fetch_tor_windows.ps1 to populate it.")
}

$torBinary = Join-Path $source 'tor.exe'
if (-not (Test-Path -LiteralPath $torBinary)) {
    throw ("$torBinary is missing, so this runtime cannot start Tor.`n" +
           "Run tool/fetch_tor_windows.ps1 to repopulate tor_runtime\windows\.")
}

New-Item -ItemType Directory -Force -Path $target | Out-Null

$copied = 0
foreach ($file in @(Get-ChildItem -LiteralPath $source -File)) {
    # README.md documents this repository; it is not part of the runtime.
    if ($file.Name -eq 'README.md') { continue }
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $target $file.Name) -Force
    $copied++
}

$totalMb = [math]::Round(
    ((Get-ChildItem -LiteralPath $target -File | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
Write-Host "Placed $copied files ($totalMb MB) in $target" -ForegroundColor Green
Write-Host 'TorBinaryLocator looks here first, so the app can start Tor immediately.' -ForegroundColor Cyan
