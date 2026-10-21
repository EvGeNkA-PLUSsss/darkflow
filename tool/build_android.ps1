# Builds and verifies the Android APK.
#
# Why this exists
# ---------------
# Two things a hand-written `flutter build apk --release` gets wrong, both of
# which are silent until a user is affected:
#
#  1. The Windows Tor runtime. Flutter bundles every asset directory declared in
#     pubspec.yaml on every platform, and pubspec has no conditional syntax, so
#     `assets/tor/windows/` (119 MB of .exe files, pluggable transports and
#     geoip data) used to end up inside the APK. None of it can execute on a
#     phone: Tor for Android ships as `jniLibs/arm64-v8a/lib*.so` instead. The
#     asset tree now declares `assets/tor/android/` as well, which holds one
#     small text file, so the correct APK is what a plain build produces. This
#     script verifies that rather than relying on it.
#
#  2. `libtor.so`. It is not produced by the Dart build: it is extracted from
#     `info.guardianproject:tor-android` and committed into jniLibs. Nothing in
#     the build notices when it goes missing, and the result installs cleanly,
#     opens, and then reports "The Tor native library is not packaged in this
#     build" the first time the user presses Connect. It went missing exactly
#     once and shipped that way; the check below is why it cannot happen twice.
#
# Release signing is taken from `android/keystore.properties`, which is not in
# version control. When that file is absent the build still works, and the script
# says plainly that the APK is debug-signed and must not be published.
#
# This file is deliberately pure ASCII. Windows PowerShell reads .ps1 files with
# the system ANSI code page unless they carry a UTF-8 BOM, so a stray em dash
# becomes mojibake and breaks the parser.
#
# Usage:  pwsh -File tool/build_android.ps1 [-Release] [-AppBundle]

[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$AppBundle
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$stagedTor = Join-Path $root 'assets\tor'

$flutter = 'D:\flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter)) {
    throw "Flutter not found at $flutter"
}

# Android Studio's JBR. The system `java` is 8 on this machine, which the Android
# Gradle Plugin refuses.
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'

$mode = if ($Release) { '--release' } else { '--debug' }

# Refuse to build an APK that cannot work.
$jniLibs = Join-Path $root 'android\app\src\main\jniLibs\arm64-v8a'
$required = @('libtor.so')
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $jniLibs $_)) })
if ($missing.Count -gt 0) {
    throw ("Missing from jniLibs: " + ($missing -join ', ') + ".`n" +
           "libtor.so comes from info.guardianproject:tor-android (see README, 'Android'), " +
           "not from the Dart build. Restore it before building.")
}
Write-Host "jniLibs check passed: $($required.Count) required binaries present." -ForegroundColor Cyan

# A staged Windows runtime must not be in the tree.
#
# `assets/tor/` is a build-time directory (see the note in pubspec.yaml), and
# whatever is in it when this runs ends up inside the APK. Unstaging first makes
# the build correct whichever order the developer worked in; the artifact check at
# the end proves it.
if (Test-Path -LiteralPath $stagedTor) {
    Write-Host 'A staged Tor runtime is present; removing it before an Android build.' -ForegroundColor Yellow
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'unstage_tor_runtime.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'unstage_tor_runtime.ps1 failed' }
}

# Report the signing situation before spending minutes on a build, not after.
$keystoreProperties = Join-Path $root 'android\keystore.properties'
$releaseNote = ''
if ($Release) {
    if (Test-Path -LiteralPath $keystoreProperties) {
        Write-Host 'Release signing: android/keystore.properties found.' -ForegroundColor Green
        $releaseNote = 'signed'
    } else {
        $releaseNote = 'debug-signed'
        Write-Warning ("android/keystore.properties is absent, so this release APK is " +
                       "signed with the DEBUG key. It cannot be published and will not " +
                       "upgrade an installation signed with a real key. " +
                       "See docs/RELEASE.md, 'Android signing'.")
    }
}

try {
    if ($AppBundle) {
        Write-Host "Building the App Bundle ($mode)..." -ForegroundColor Cyan
        & $flutter build appbundle $mode
        if ($LASTEXITCODE -ne 0) { throw "flutter build appbundle failed with exit code $LASTEXITCODE" }
        $artifact = Join-Path $root 'build\app\outputs\bundle\release\app-release.aab'
    } else {
        Write-Host "Building the APK ($mode)..." -ForegroundColor Cyan
        & $flutter build apk $mode
        if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed with exit code $LASTEXITCODE" }
        $name = if ($Release) { 'app-release.apk' } else { 'app-debug.apk' }
        $artifact = Join-Path $root "build\app\outputs\flutter-apk\$name"
    }

    if (-not (Test-Path -LiteralPath $artifact)) {
        throw "Expected artifact was not produced: $artifact"
    }

    # The whole point of the asset split: prove the Windows runtime is not inside.
    #
    # An APK is a zip, and a release build can be over 100 MB, so this reads the
    # central directory rather than extracting anything.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($artifact)
    try {
        $entries = $zip.Entries
        $windowsEntries = @($entries | Where-Object { $_.FullName -like '*assets/tor/windows/*' })
        $androidEntries = @($entries | Where-Object { $_.FullName -like '*assets/tor/android/*' })
        $torLib = @($entries | Where-Object { $_.FullName -like '*lib/arm64-v8a/libtor.so' })

        $windowsMb = [math]::Round((($windowsEntries | Measure-Object -Property Length -Sum).Sum) / 1MB, 2)
        $totalMb = [math]::Round((Get-Item -LiteralPath $artifact).Length / 1MB, 1)

        Write-Host "Artifact: $artifact ($totalMb MB, $releaseNote)" -ForegroundColor Green
        Write-Host "  assets/tor/windows entries : $($windowsEntries.Count) ($windowsMb MB)"
        Write-Host "  assets/tor/android entries : $($androidEntries.Count)"
        Write-Host "  lib/arm64-v8a/libtor.so    : $($torLib.Count)"

        if ($windowsEntries.Count -gt 0) {
            throw ("The Windows Tor runtime is inside this artifact ($($windowsEntries.Count) files, " +
                   "$windowsMb MB). It cannot execute on Android and must not ship. " +
                   "Run tool/unstage_tor_runtime.ps1 and rebuild.")
        }
        if ($torLib.Count -eq 0) {
            throw ("libtor.so is not inside this artifact, so Tor can never start on the device. " +
                   "Restore it from info.guardianproject:tor-android before publishing.")
        }
        Write-Host 'Artifact verification passed: no Windows runtime, libtor.so present.' -ForegroundColor Green

        $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
        Write-Host "SHA-256: $hash"
    } finally {
        $zip.Dispose()
    }
} finally {
    # Nothing is staged by this script, so there is nothing to put back. A leftover
    # stash from an older version of this file would otherwise sit in the working
    # tree unnoticed, which is worth one line of warning.
    $legacyStash = Join-Path $root 'tool\tor_runtime_windows'
    if (Test-Path -LiteralPath $legacyStash) {
        Write-Warning ("$legacyStash exists, left over from an older version of this script. " +
                       "Move its contents to tor_runtime\windows\ and delete the directory.")
    }
}
