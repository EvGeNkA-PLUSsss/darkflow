#Requires -Version 5.1
<#
.SYNOPSIS
    Produces a releaseable DarkFlow build for Windows and/or Android.

.DESCRIPTION
    One entry point for a release, because the two platforms have to agree about
    three things that are easy to get wrong by hand and impossible to notice
    afterwards:

      1. THE VERSION. `pubspec.yaml` is the single source of truth. Its `version:`
         line is split into name and build number and passed to the Dart compiler
         as `--dart-define`, so the About screen, the crash-free diagnostic report
         and the Android manifest all name the same build. The app's own constant
         is a `String.fromEnvironment` with a deliberately implausible default
         ("0.0.0-dev"), so a build that skipped this script is recognisable rather
         than quietly claiming to be a release.

      2. THE ARTIFACT CHECK. An APK that carries the 119 MB Windows Tor runtime
         installs and opens and is simply wrong; `libtor.so` going missing from
         jniLibs produces an app that fails the first time a user presses Connect.
         Both are verified by reading the built artifact rather than by trusting
         the build, which is the only way to catch them - neither breaks the build.

      3. THE SIGNING STATE. A build signed with a debug key cannot be published and
         will not upgrade an existing installation. That is reported loudly here
         rather than discovered at upload time.

    Nothing is signed inside this script except by deferring to the platform
    tools: `signtool` for Windows and the Gradle signing config for Android. Both
    are optional and their absence is a warning, not a failure, so the script is
    useful on a machine that has no keys.

    This file is deliberately pure ASCII. Windows PowerShell reads .ps1 files with
    the system ANSI code page unless they carry a UTF-8 BOM, so a non-ASCII
    character becomes mojibake and can break the parser.

.PARAMETER Target
    windows, android, or both. Defaults to both.

.PARAMETER SkipTests
    Skip `flutter analyze` and `flutter test`. Only for iterating on packaging;
    a release should never be produced with this switch.

.PARAMETER CertThumbprint
    SHA-1 thumbprint of a code-signing certificate in the current user's store,
    used to sign the Windows executable. Omit to skip signing.

.PARAMETER TimestampUrl
    RFC 3161 timestamp server. Defaults to DigiCert's. A signature without a
    timestamp stops being valid when the certificate expires, which for a
    release binary means it cannot be verified years later.

.EXAMPLE
    pwsh -File tool/release.ps1
    Builds both platforms, runs the checks, and reports what is (not) signed.

.EXAMPLE
    pwsh -File tool/release.ps1 -Target android -CertThumbprint ABC123...
    Builds and signs Android, and signs the Windows binary with the given
    certificate (the thumbprint is only used for the Windows target).
#>
[CmdletBinding()]
param(
    [ValidateSet('windows', 'android', 'both')]
    [string]$Target = 'both',

    [switch]$SkipTests,

    [string]$CertThumbprint = '',

    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$flutter = 'D:\flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter)) {
    throw "Flutter not found at $flutter"
}

# Android Studio's JBR. The system `java` on this machine is 8, which the Android
# Gradle Plugin refuses.
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text) {
    Write-Host "   OK  $Text" -ForegroundColor Green
}

function Write-Warn2([string]$Text) {
    Write-Host "   !!  $Text" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- version

Write-Step 'Reading the version from pubspec.yaml'

$pubspec = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw
$match = [regex]::Match($pubspec, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?\s*$')
if (-not $match.Success) {
    throw "pubspec.yaml has no usable 'version: x.y.z+n' line. Found no match."
}
$versionName = $match.Groups[1].Value
$buildNumber = if ($match.Groups[2].Success) { $match.Groups[2].Value } else { '0' }

Write-Ok "version $versionName+$buildNumber"

# `--dart-define` values. DARKFLOW_RELEASE marks the build as a real one so the
# About screen stops saying "development build".
$defines = @(
    '--dart-define=DARKFLOW_VERSION=' + $versionName,
    '--dart-define=DARKFLOW_BUILD_NUMBER=' + $buildNumber,
    '--dart-define=DARKFLOW_RELEASE=true'
)

# ---------------------------------------------------------------- preflight

if (-not $SkipTests) {
    Write-Step 'flutter analyze'
    & $flutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'flutter analyze reported problems; fix them before releasing.' }
    Write-Ok 'no analyzer issues'

    # The integration tests are excluded deliberately, not to save time.
    #
    # They start a real Tor daemon and wait on the network, and running them beside the unit
    # tests starves the suite: `test/features/image_preview_test.dart` failed with "The file
    # vault is locked" and thirty-second timeouts in one run and passed in the next, purely
    # because of what it was competing with. A gate that fails at random is not a gate.
    #
    # They are worth running when packaging changes, and that is a deliberate act:
    #
    #     flutter test --tags integration
    Write-Step 'flutter test'
    & $flutter test --exclude-tags integration
    if ($LASTEXITCODE -ne 0) { throw 'the test suite failed; fix it before releasing.' }
    Write-Ok 'test suite passed'
} else {
    Write-Warn2 'checks skipped (-SkipTests). Do not publish this build.'
}

$produced = @()

# ---------------------------------------------------------------- windows

if ($Target -eq 'windows' -or $Target -eq 'both') {
    Write-Step 'Windows release build'

    & $flutter build windows --release @defines
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed with exit code $LASTEXITCODE" }

    # The Tor runtime is placed beside the executable after the build, not carried
    # inside the asset bundle. Flutter copies every declared asset directory into
    # every build on every platform, so an asset-bundled Windows runtime ends up
    # inside the Android APK; a sibling directory cannot. See the note in
    # lib/src/tor/tor_paths.dart.
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'stage_tor_runtime.ps1') -Configuration Release
    if ($LASTEXITCODE -ne 0) { throw 'stage_tor_runtime.ps1 failed' }

    $exe = Join-Path $root 'build\windows\x64\runner\Release\darkflow.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "expected $exe, which was not produced" }
    Write-Ok "built $exe"

    # The runtime has to have landed, because the app starts Tor from there. A
    # release that lost it installs cleanly and then fails on the first Connect.
    $runtimeDir = Join-Path $root 'build\windows\x64\runner\Release\tor'
    $torExe = Join-Path $runtimeDir 'tor.exe'
    if (-not (Test-Path -LiteralPath $torExe)) {
        throw ("The Tor runtime is not beside the built executable ($torExe is absent). " +
               "The app would install and be unable to start Tor.")
    }
    $count = @(Get-ChildItem -LiteralPath $runtimeDir -File).Count
    $runtimeMb = [math]::Round(
        ((Get-ChildItem -LiteralPath $runtimeDir -File | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
    Write-Ok "Tor runtime beside the executable ($count files, $runtimeMb MB)"

    if ($CertThumbprint) {
        Write-Step "Signing darkflow.exe with certificate $CertThumbprint"
        $signtool = Get-Command 'signtool.exe' -ErrorAction SilentlyContinue
        if ($null -eq $signtool) {
            Write-Warn2 'signtool.exe is not on PATH, so the binary was NOT signed.'
            Write-Warn2 'It ships with the Windows SDK (Windows Kits\10\bin\<ver>\x64).'
        } else {
            & $signtool.Source sign /sha1 $CertThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $exe
            if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE" }
            Write-Ok 'signed and timestamped'
        }
    } else {
        Write-Warn2 'No -CertThumbprint given, so darkflow.exe is UNSIGNED.'
        Write-Warn2 'Windows SmartScreen will warn every user until it is signed.'
    }

    $produced += [pscustomobject]@{
        Platform = 'windows'
        Path     = $exe
        # What a user actually downloads. The executable is 90 KB: the
        # distribution is this directory, and it is 151 MB because Tor is 119 MB of
        # it. Reporting the .exe alone made a Windows release look smaller than it
        # is by three orders of magnitude, which is exactly the kind of number
        # somebody puts in release notes.
        ShipPath = (Split-Path -Parent $exe)
        Signed   = [bool]$CertThumbprint
    }
}

# ---------------------------------------------------------------- android

if ($Target -eq 'android' -or $Target -eq 'both') {
    Write-Step 'Android release APK'

    # The Android build is driven by the platform script, which verifies the
    # artifact: no Windows runtime inside, libtor.so present.
    $androidArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                     '-File', (Join-Path $PSScriptRoot 'build_android.ps1'), '-Release')
    & powershell @androidArgs
    if ($LASTEXITCODE -ne 0) { throw "the Android build failed (see the output above)" }

    $apk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
    if (-not (Test-Path -LiteralPath $apk)) { throw "expected $apk, which was not produced" }

    $keystore = Join-Path $root 'android\keystore.properties'
    $signed = Test-Path -LiteralPath $keystore
    if (-not $signed) {
        Write-Warn2 'android/keystore.properties is absent, so this APK is DEBUG-SIGNED.'
        Write-Warn2 'It cannot be published. See docs/RELEASE.md, "Android signing".'
    }

    $produced += [pscustomobject]@{
        Platform = 'android'
        Path     = $apk
        ShipPath = $apk
        Signed   = $signed
    }
}

# ---------------------------------------------------------------- summary

Write-Step 'Release summary'

# The total of what ships, which for Windows is a directory rather than a file.
function Get-ShipBytes([string]$path) {
    if (Test-Path -LiteralPath $path -PathType Container) {
        return (Get-ChildItem -LiteralPath $path -Recurse -File |
                Measure-Object -Property Length -Sum).Sum
    }
    return (Get-Item -LiteralPath $path).Length
}

$table = foreach ($item in $produced) {
    [pscustomobject]@{
        Platform = $item.Platform
        Ships    = $item.ShipPath
        SizeMB   = [math]::Round((Get-ShipBytes $item.ShipPath) / 1MB, 1)
        Signed   = if ($item.Signed) { 'yes' } else { 'NO' }
        SHA256   = (Get-FileHash -LiteralPath $item.Path -Algorithm SHA256).Hash
    }
}
$table | Format-List

Write-Host 'Hashes above are of the built executable or APK. For Windows, verify the' -ForegroundColor Cyan
Write-Host 'whole distribution directory as well: it is what users download, and the' -ForegroundColor Cyan
Write-Host 'Tor runtime inside it is not covered by the executable''s hash.' -ForegroundColor Cyan

$published = @($produced | Where-Object { -not $_.Signed })
if ($published.Count -gt 0) {
    Write-Host ''
    Write-Warn2 'At least one artifact is unsigned or debug-signed.'
}
Write-Host ''
Write-Host 'Publishable paths:' -ForegroundColor Cyan
foreach ($item in $produced) { Write-Host "  $($item.ShipPath)" }
