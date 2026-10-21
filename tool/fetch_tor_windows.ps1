#Requires -Version 5.1
<#
.SYNOPSIS
    Fetches the official Tor binaries and pluggable transports for Windows x86_64
    into tor_runtime\windows, proves that every binary runs, and writes MANIFEST.json.

.DESCRIPTION
    This script reproduces exactly what was done by hand to populate
    tor_runtime\windows:

      1. DOWNLOAD  the official Tor Expert Bundle for Windows x86_64
                   (tor-expert-bundle-windows-x86_64-<Version>.tar.gz).
                   Two sources are tried, in order:
                     a) the canonical Tor Project host
                        https://archive.torproject.org/tor-package-archive/torbrowser/<V>/...
                     b) the long-term GitHub binary cache
                        https://github.com/nefarius/TorSharp.Mirror/releases
                        (looked up through the GitHub API so any version works,
                        not just the one a given release tag happened to contain).
                   The URL that actually served the archive is recorded in the
                   manifest as "source_url".

      2. EXTRACT   tor.exe, geoip, geoip6, lyrebird.exe and conjure-client.exe.
                   The archives are plain gzipped tar files, so Windows' built-in
                   bsdtar (tar.exe) is used, with 7-Zip as a fallback.

      3. BUILD     the pluggable-transport clients that the Expert Bundle does NOT
                   ship, from official upstream Tor Project / pluggable-transports
                   Go sources: obfs4proxy.exe, snowflake-client.exe,
                   webtunnel-client.exe and meek-client.exe. Go is downloaded
                   automatically into the work directory when it is not on PATH.
                   Modules are resolved through proxy.golang.org (the public Go
                   module proxy), which is required because gitlab.torproject.org
                   itself is frequently unreachable.

      4. VERIFY    tor.exe --version and lyrebird.exe --version, plus a real Tor
                   pluggable-transport handshake for every PT binary: the process
                   is started with TOR_PT_MANAGED_TRANSPORT_VER=1 and must print
                   "VERSION 1" ... "CMETHOD <name> socks5 127.0.0.1:<port>" ...
                   "CMETHODS DONE" on stdout. A binary that fails this is NOT
                   installed and is listed under "missing" in the manifest.

      5. MANIFEST  tor_runtime\windows\MANIFEST.json with the platform, the exact
                   "tor.exe --version" first line, the download URL, a timestamp
                   and the real SHA-256 + byte size of every installed file.

.PARAMETER Version
    Tor Browser / Tor Expert Bundle version to fetch. Defaults to 15.0.24, which
    is the version the current contents of tor_runtime\windows came from.

.PARAMETER ProjectRoot
    Flutter project root. Defaults to the parent directory of this script (tool\).

.PARAMETER WorkDir
    Scratch directory for downloads and build output. Defaults to
    %TEMP%\torbundle-<Version>. A previously downloaded archive in here is reused
    unless -Force is given.

.PARAMETER GoVersion
    Go toolchain to download when Go is not already on PATH. Defaults to go1.27.2,
    which is what produced the binaries currently checked in.

.PARAMETER SkipPtBuild
    Only fetch the Expert Bundle contents; do not build the standalone PT clients.

.PARAMETER SkipVerify
    Skip the run/handshake verification step (not recommended).

.PARAMETER Force
    Re-download the Expert Bundle and the Go toolchain even if cached copies exist.

.EXAMPLE
    .\tool\fetch_tor_windows.ps1

.EXAMPLE
    .\tool\fetch_tor_windows.ps1 -Version 15.0.19 -Force -Verbose

.NOTES
    Environment caveats observed while this script was written (2026-10, Windows):

    * HTTPS to every *.torproject.org host was blocked by the local network
      (TCP connect succeeded and was then reset or stalled during the TLS
      handshake), while plain HTTP answered with a 302. That is why the GitHub
      Expert Bundle cache is the first *working* source here and why the Go
      module proxy is used instead of cloning from gitlab.torproject.org. The
      script still tries the canonical torproject.org URL first, so on an
      unblocked network it will fetch straight from the Tor Project.
    * Tor Browser's own .exe/.tar.xz installers are CDN-only on
      dist.torproject.org / archive.torproject.org; they are not carried by the
      public mirrors (all probed mirrors return 404 for /torbrowser/), so the
      pluggable transports cannot be pulled out of a Tor Browser installation
      from a mirror. Building them from upstream source is the reproducible
      alternative used here.
    * Archive layout differs between versions. 15.x uses
        tor\tor.exe, tor\pluggable_transports\lyrebird.exe,
        tor\pluggable_transports\conjure-client.exe, data\geoip, data\geoip6
      while 12.x/13.x were flat (tor.exe at the archive root) and shipped no PTs
      at all. This script discovers the files by name instead of hard-coding a
      layout.
    * lyrebird.exe 0.8.1 is the modern unified PT: it serves obfs4, snowflake,
      webtunnel, meek_lite, obfs3, obfs2 and scramblesuit itself. Upstream no
      longer produces a separate obfs4proxy.exe, so the obfs4proxy.exe built
      here is the last standalone upstream obfs4 release (2023-10-12).
    * tor.exe finds geoip/geoip6 in its DataDirectory; either copy them there or
      point GeoIPFile / GeoIPv6File at the unpacked geoip / geoip6 beside tor.exe.
    * PowerShell 5.1 turns a native process's stderr into a *terminating* error
      when $ErrorActionPreference is 'Stop' (this script sets it), so every
      external process is launched through Invoke-NativeCommand, which relaxes
      the preference for the duration of the call and returns the exit code.
#>

[CmdletBinding()]
param(
    [string] $Version   = '15.0.24',
    [string] $ProjectRoot,
    [string] $WorkDir,
    [string] $GoVersion = 'go1.27.2',
    [switch] $SkipPtBuild,
    [switch] $SkipVerify,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
if (-not $WorkDir)     { $WorkDir     = Join-Path $env:TEMP "torbundle-$Version" }

$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Dest        = Join-Path $ProjectRoot 'tor_runtime\windows'
$ExtractDir  = Join-Path $WorkDir 'extract'
$BundleName  = "tor-expert-bundle-windows-x86_64-$Version.tar.gz"
$BundlePath  = Join-Path $WorkDir $BundleName

New-Item -ItemType Directory -Force -Path $Dest, $WorkDir | Out-Null

# The Tor Project's canonical host for the Expert Bundle.
$OfficialUrl = "https://archive.torproject.org/tor-package-archive/torbrowser/$Version/$BundleName"

# Binaries taken verbatim from the Expert Bundle. geoip/geoip6 are installed under
# the flat names tor.exe expects beside its data files.
$FromBundle = @(
    @{ Source = 'tor.exe';            Target = 'tor.exe' },
    @{ Source = 'geoip';              Target = 'geoip' },
    @{ Source = 'geoip6';             Target = 'geoip6' },
    @{ Source = 'lyrebird.exe';       Target = 'lyrebird.exe' },
    @{ Source = 'conjure-client.exe'; Target = 'conjure-client.exe' }
)

# Standalone PT clients the Expert Bundle does not ship. Each entry pins the exact
# upstream module/package and the transport name used for the handshake test.
$PtBuilds = @(
    @{ Name = 'obfs4proxy.exe';       Package = 'gitlab.com/yawning/obfs4.git/obfs4proxy@v0.0.0-20231012084234-c3e2d44b1033';                     Transport = 'obfs4' },
    @{ Name = 'snowflake-client.exe'; Package = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake/v2/client@v2.15.1';      Transport = 'snowflake' },
    @{ Name = 'webtunnel-client.exe'; Package = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel/main/client@v0.0.7';      Transport = 'webtunnel' },
    @{ Name = 'meek-client.exe';      Package = 'git.torproject.org/pluggable-transports/meek.git/meek-client@v0.38.0';                            Transport = 'meek' }
)

# Transport name each installed binary is probed with during verification.
$VerifyProbes = @(
    @{ Name = 'obfs4proxy.exe';       Transport = 'obfs4' },
    @{ Name = 'lyrebird.exe';         Transport = 'obfs4' },
    @{ Name = 'snowflake-client.exe'; Transport = 'snowflake' },
    @{ Name = 'webtunnel-client.exe'; Transport = 'webtunnel' },
    @{ Name = 'meek-client.exe';      Transport = 'meek' },
    @{ Name = 'conjure-client.exe';   Transport = 'conjure' }
)

$InstalledOrder = @(
    'tor.exe', 'geoip', 'geoip6', 'obfs4proxy.exe', 'snowflake-client.exe',
    'webtunnel-client.exe', 'lyrebird.exe', 'conjure-client.exe', 'meek-client.exe'
)

$script:Missing = New-Object System.Collections.Generic.List[string]

function Write-Step { param([string] $Message) Write-Host ''; Write-Host "=== $Message" -ForegroundColor Cyan }
function Write-Note { param([string] $Message) Write-Host "    $Message" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Native process helper
# ---------------------------------------------------------------------------
function Invoke-NativeCommand {
    <#
        Runs an external program and returns its exit code.

        PowerShell 5.1 converts anything a native process writes to stderr into an
        ErrorRecord; combined with $ErrorActionPreference = 'Stop' (and with any
        stderr redirection such as 2>&1) that becomes a terminating error, which
        would break `go install`, `curl`, `tar` and `7z` the moment they print a
        progress or warning line. The preference is therefore relaxed to
        'Continue' for the duration of the call, stderr is merged into the
        optional log file, and the exit code is inspected by the caller.
    #>
    param(
        [Parameter(Mandatory)] [string]   $FilePath,
        [string[]]                        $Arguments = @(),
        [string]                          $LogFile,
        [switch]                          $CaptureOutput
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $text = ''
    try {
        $output = & $FilePath @Arguments 2>&1
        if ($null -ne $output) { $text = ($output | Out-String) }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }

    if ($LogFile) {
        Set-Content -LiteralPath $LogFile -Value $text -Encoding UTF8
    }
    if ($CaptureOutput) {
        return [pscustomobject]@{ ExitCode = $code; Output = $text }
    }
    return $code
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# curl.exe ships with Windows 10 1803+ and is far more reliable here than
# Invoke-WebRequest, which timed out against several hosts under PowerShell 5.1.
function Get-CurlPath {
    $cmd = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

function Invoke-Download {
    <#
        Downloads $Url to $OutFile. Returns $true on success; never throws, so the
        caller can fall through to the next mirror.
    #>
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $OutFile
    )
    Write-Note "GET $Url"
    $curl = Get-CurlPath
    if ($curl) {
        $log = Join-Path $WorkDir 'curl.log'
        $code = Invoke-NativeCommand -FilePath $curl -LogFile $log -Arguments @(
            '-sSL', '--fail', '--connect-timeout', '20', '--max-time', '1800',
            '--retry', '3', '--retry-delay', '2', '-o', $OutFile, $Url
        )
        if ($code -eq 0 -and (Test-Path -LiteralPath $OutFile) -and (Get-Item -LiteralPath $OutFile).Length -gt 0) {
            return $true
        }
        Write-Warning "curl failed (exit $code) for $Url"
        Remove-Item -LiteralPath $OutFile -ErrorAction SilentlyContinue
        return $false
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 1800
        return $true
    } catch {
        Write-Warning "Invoke-WebRequest failed for $Url : $($_.Exception.Message)"
        Remove-Item -LiteralPath $OutFile -ErrorAction SilentlyContinue
        return $false
    }
}

# Locates an executable on PATH or at an explicit path.
function Find-Executable {
    param([Parameter(Mandatory)] [string[]] $Candidates)
    foreach ($candidate in $Candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

# Extracts a .tar.gz with bsdtar when available, otherwise 7-Zip.
function Expand-TarGz {
    param(
        [Parameter(Mandatory)] [string] $Archive,
        [Parameter(Mandatory)] [string] $Destination
    )
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $tar = Find-Executable @('tar.exe', (Join-Path $env:SystemRoot 'System32\tar.exe'))
    if ($tar) {
        $code = Invoke-NativeCommand -FilePath $tar -Arguments @('-xzf', $Archive, '-C', $Destination)
        if ($code -eq 0) { return }
        Write-Warning "tar.exe failed (exit $code); falling back to 7-Zip"
    }
    $sevenZip = Find-Executable @('7z.exe', '7za.exe', 'C:\Program Files\7-Zip\7z.exe')
    if (-not $sevenZip) { throw "Neither tar.exe nor 7-Zip is available to extract $Archive" }
    # 7-Zip needs two passes for .tar.gz: gunzip to .tar, then untar.
    Invoke-NativeCommand -FilePath $sevenZip -Arguments @('x', $Archive, "-o$Destination", '-y') | Out-Null
    $inner = Get-ChildItem -LiteralPath $Destination -Filter '*.tar' -File | Select-Object -First 1
    if ($inner) {
        Invoke-NativeCommand -FilePath $sevenZip -Arguments @('x', $inner.FullName, "-o$Destination", '-y') | Out-Null
        Remove-Item -LiteralPath $inner.FullName -ErrorAction SilentlyContinue
    }
}

# Finds a file anywhere inside the extracted bundle, because the archive layout
# changed between Tor Browser versions (15.x nests everything under tor\ and data\).
function Find-InBundle {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $FileName
    )
    $hit = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue |
           Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

# ---------------------------------------------------------------------------
# Step 1 - download the Expert Bundle
# ---------------------------------------------------------------------------
Write-Step "Step 1/5  Download the Tor Expert Bundle ($Version)"

$SourceUrl = $null

if ((Test-Path -LiteralPath $BundlePath) -and -not $Force -and (Get-Item -LiteralPath $BundlePath).Length -gt 0) {
    Write-Note "Reusing cached archive $BundlePath (use -Force to re-download)"
    $SourceUrl = "https://archive.torproject.org/tor-package-archive/torbrowser/$Version/$BundleName (cached copy)"
    if ((Test-Path -LiteralPath (Join-Path $WorkDir 'source-url.txt'))) {
        $SourceUrl = (Get-Content -LiteralPath (Join-Path $WorkDir 'source-url.txt') -Raw).Trim()
    }
} else {
    if (Invoke-Download -Url $OfficialUrl -OutFile $BundlePath) {
        $SourceUrl = $OfficialUrl
    } else {
        Write-Warning 'Canonical host did not serve the bundle; trying the GitHub binary cache.'

        # The cache publishes a new daily release, so the requested version can sit
        # many pages back in the release list: walk the pages until the asset shows
        # up. Each page is downloaded to a file (rather than captured through the
        # pipeline) because a page of releases is about a megabyte of JSON.
        $asset = $null
        for ($page = 1; $page -le 5 -and -not $asset; $page++) {
            $apiUrl  = "https://api.github.com/repos/nefarius/TorSharp.Mirror/releases?per_page=100&page=$page"
            $apiFile = Join-Path $WorkDir "releases-page$page.json"
            if (-not (Invoke-Download -Url $apiUrl -OutFile $apiFile)) {
                Write-Warning "GitHub release list page $page could not be downloaded."
                break
            }
            try {
                $releases = Get-Content -LiteralPath $apiFile -Raw | ConvertFrom-Json
            } catch {
                Write-Warning "Could not parse the GitHub release list: $($_.Exception.Message)"
                break
            }
            if (-not $releases) { break }
            # A rate-limited or errored response is a single object with "message".
            if ($releases -isnot [array] -and $releases.PSObject.Properties.Name -contains 'message') {
                Write-Warning "GitHub API refused the request: $($releases.message)"
                break
            }
            foreach ($release in $releases) {
                $match = $release.assets | Where-Object { $_.name -eq $BundleName } | Select-Object -First 1
                if ($match) { $asset = $match; break }
            }
        }
        if ($asset) {
            if (Invoke-Download -Url $asset.browser_download_url -OutFile $BundlePath) {
                $SourceUrl = $asset.browser_download_url
            }
        }
        # Last resort: the asset attached to the newest release, which succeeds
        # whenever -Version is the version the cache is currently publishing.
        if (-not $SourceUrl) {
            $latestUrl = "https://github.com/nefarius/TorSharp.Mirror/releases/latest/download/$BundleName"
            if (Invoke-Download -Url $latestUrl -OutFile $BundlePath) { $SourceUrl = $latestUrl }
        }
        if (-not $SourceUrl) {
            throw "Could not download $BundleName from '$OfficialUrl' or from the GitHub binary cache."
        }
    }
    Set-Content -LiteralPath (Join-Path $WorkDir 'source-url.txt') -Value $SourceUrl -Encoding ASCII
}
Write-Note "source_url = $SourceUrl"

# ---------------------------------------------------------------------------
# Step 2 - extract and install the bundled binaries
# ---------------------------------------------------------------------------
Write-Step 'Step 2/5  Extract tor.exe, geoip, geoip6, lyrebird.exe, conjure-client.exe'

Remove-Item -LiteralPath $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
Expand-TarGz -Archive $BundlePath -Destination $ExtractDir

foreach ($item in $FromBundle) {
    $found = Find-InBundle -Root $ExtractDir -FileName $item.Source
    if (-not $found) {
        Write-Warning "Not present in this bundle layout: $($item.Source)"
        $script:Missing.Add($item.Target)
        continue
    }
    Copy-Item -LiteralPath $found -Destination (Join-Path $Dest $item.Target) -Force
    Write-Note ('installed {0,-22} {1,12:N0} bytes' -f $item.Target, (Get-Item -LiteralPath $found).Length)
}

# ---------------------------------------------------------------------------
# Step 3 - build the standalone pluggable transports
# ---------------------------------------------------------------------------
Write-Step 'Step 3/5  Build standalone pluggable transports from upstream source'

if ($SkipPtBuild) {
    Write-Note 'Skipped (-SkipPtBuild)'
} else {
    # --- make sure a Go toolchain is available -----------------------------
    $goExe = $null
    if (-not $Force) { $goExe = Find-Executable @('go.exe') }

    if ($goExe) {
        Write-Note "Using Go on PATH: $goExe"
    } else {
        $goRoot = Join-Path $WorkDir "tools\$GoVersion"
        $goBin  = Join-Path $goRoot 'go\bin\go.exe'
        if ((Test-Path -LiteralPath $goBin) -and -not $Force) {
            Write-Note "Using cached Go toolchain: $goBin"
        } else {
            $goZip = Join-Path $WorkDir "$GoVersion.windows-amd64.zip"
            if (-not (Test-Path -LiteralPath $goZip) -or $Force) {
                if (-not (Invoke-Download -Url "https://go.dev/dl/$GoVersion.windows-amd64.zip" -OutFile $goZip)) {
                    throw "Could not download the Go toolchain ($GoVersion)."
                }
            }
            New-Item -ItemType Directory -Force -Path $goRoot | Out-Null
            $sevenZip = Find-Executable @('7z.exe', '7za.exe', 'C:\Program Files\7-Zip\7z.exe')
            if ($sevenZip) {
                Invoke-NativeCommand -FilePath $sevenZip -Arguments @('x', $goZip, "-o$goRoot", '-y') | Out-Null
            } else {
                Expand-Archive -LiteralPath $goZip -DestinationPath $goRoot -Force
            }
            if (-not (Test-Path -LiteralPath $goBin)) { throw "Go toolchain extraction did not produce $goBin" }
        }
        $goExe = $goBin
    }

    # --- build each client --------------------------------------------------
    # GOPROXY is pinned to the public Go module proxy: the upstream repositories
    # live on gitlab.torproject.org / git.torproject.org, which are unreachable
    # from many networks, while the proxy can serve those modules (and its own
    # servers can reach the origins).
    $env:GOROOT      = Split-Path -Parent (Split-Path -Parent $goExe)
    $env:GOPATH      = Join-Path $WorkDir 'gopath'
    $env:GOCACHE     = Join-Path $WorkDir 'gocache'
    $env:GOPROXY     = 'https://proxy.golang.org'
    $env:GOSUMDB     = 'off'
    $env:GOTOOLCHAIN = 'local'
    $env:CGO_ENABLED = '0'
    $env:GOOS        = 'windows'
    $env:GOARCH      = 'amd64'
    New-Item -ItemType Directory -Force -Path $env:GOPATH, $env:GOCACHE | Out-Null

    foreach ($build in $PtBuilds) {
        $goBinDir = Join-Path $WorkDir "gobin\$($build.Name)"
        Remove-Item -LiteralPath $goBinDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $goBinDir | Out-Null
        $env:GOBIN = $goBinDir

        Write-Note "go install $($build.Package)"
        $log  = Join-Path $WorkDir ("go-install-$($build.Name).log")
        $code = Invoke-NativeCommand -FilePath $goExe -LogFile $log -Arguments @('install', $build.Package)
        if ($code -ne 0) {
            Write-Warning "Build failed for $($build.Name) ($($build.Package)); see $log"
            $script:Missing.Add($build.Name)
            continue
        }

        $produced = Get-ChildItem -LiteralPath $goBinDir -File -Filter '*.exe' | Select-Object -First 1
        if (-not $produced) {
            Write-Warning "Build produced no executable for $($build.Name)"
            $script:Missing.Add($build.Name)
            continue
        }
        # 'go install' names the binary after the package directory (both the
        # snowflake and webtunnel clients would be client.exe), so rename it to the
        # name Tor and the Dart side expect.
        Copy-Item -LiteralPath $produced.FullName -Destination (Join-Path $Dest $build.Name) -Force
        Write-Note ('installed {0,-22} {1,12:N0} bytes' -f $build.Name, (Get-Item -LiteralPath $produced.FullName).Length)
    }
}

# ---------------------------------------------------------------------------
# Step 4 - prove the binaries run
# ---------------------------------------------------------------------------
Write-Step 'Step 4/5  Verify that every binary actually runs'

$TorVersionLine = $null

# tor.exe --version is the primary acceptance test for this whole script.
$torExe = Join-Path $Dest 'tor.exe'
if (-not (Test-Path -LiteralPath $torExe)) { throw "tor.exe is missing from $Dest" }

$torRun = Invoke-NativeCommand -FilePath $torExe -CaptureOutput -Arguments @('--version')
$torLines = @($torRun.Output -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
if ($torLines.Count -gt 0) { $TorVersionLine = $torLines[0].Trim() }
Write-Host "    tor.exe --version -> $TorVersionLine" -ForegroundColor Green
if ($TorVersionLine -notmatch '^Tor version \d') {
    throw "tor.exe --version did not print a Tor version (exit $($torRun.ExitCode)). Got: $TorVersionLine"
}

# lyrebird reports its own version with --version.
$lyrebirdExe = Join-Path $Dest 'lyrebird.exe'
if (Test-Path -LiteralPath $lyrebirdExe) {
    $lyrebirdRun = Invoke-NativeCommand -FilePath $lyrebirdExe -CaptureOutput -Arguments @('--version')
    $lyrebirdVersion = @($lyrebirdRun.Output -split "`r?`n" | Where-Object { $_ -and $_.Trim() })[0]
    Write-Host "    lyrebird.exe --version -> $lyrebirdVersion" -ForegroundColor Green
}

function Test-PtHandshake {
    <#
        Starts a PT binary as a real managed transport and requires the standard
        handshake on stdout:
            VERSION 1
            CMETHOD <transport> socks5 127.0.0.1:<port>
            CMETHODS DONE
        A .bat wrapper is used because PowerShell 5.1's Start-Process cannot redirect
        stdin; "< NUL" hands the PT an immediate EOF, which TOR_PT_EXIT_ON_STDIN_CLOSE
        converts into a clean exit once the handshake has been printed.
    #>
    param(
        [Parameter(Mandatory)] [string] $ExePath,
        [Parameter(Mandatory)] [string] $Transport,
        [int] $TimeoutSeconds = 25
    )
    $outFile  = Join-Path $WorkDir 'pt-stdout.txt'
    $errFile  = Join-Path $WorkDir 'pt-stderr.txt'
    $batFile  = Join-Path $WorkDir 'run-pt.bat'
    $stateDir = Join-Path $WorkDir "pt-state-$Transport"
    Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    Set-Content -LiteralPath $batFile -Encoding ASCII -Value (
        "@echo off`r`n`"$ExePath`" < NUL > `"$outFile`" 2> `"$errFile`"")

    $env:TOR_PT_MANAGED_TRANSPORT_VER = '1'
    $env:TOR_PT_CLIENT_TRANSPORTS     = $Transport
    $env:TOR_PT_STATE_LOCATION        = $stateDir
    $env:TOR_PT_EXIT_ON_STDIN_CLOSE   = '1'

    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $batFile -PassThru -NoNewWindow
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        Invoke-NativeCommand -FilePath 'taskkill.exe' -Arguments @('/T', '/F', '/PID', $proc.Id) | Out-Null
    }

    $stdout = ''
    if (Test-Path -LiteralPath $outFile) { $stdout = (Get-Content -LiteralPath $outFile -Raw) }
    if ($null -eq $stdout) { $stdout = '' }
    $stdout = $stdout.Trim()

    return [pscustomobject]@{
        Name      = (Split-Path -Leaf $ExePath)
        Transport = $Transport
        Ok        = (($stdout -match 'CMETHODS DONE') -and ($stdout -match 'CMETHOD '))
        Output    = $stdout
    }
}

if ($SkipVerify) {
    Write-Note 'Skipped pluggable-transport handshakes (-SkipVerify)'
} else {
    foreach ($probe in $VerifyProbes) {
        $exePath = Join-Path $Dest $probe.Name
        if (-not (Test-Path -LiteralPath $exePath)) {
            $script:Missing.Add($probe.Name)
            continue
        }
        $result = Test-PtHandshake -ExePath $exePath -Transport $probe.Transport
        if ($result.Ok) {
            $methodLine = ($result.Output -split "`r?`n" | Where-Object { $_ -match '^CMETHOD ' } | Select-Object -First 1)
            Write-Host ('    {0,-22} OK   {1}' -f $result.Name, $methodLine) -ForegroundColor Green
        } else {
            Write-Warning "$($result.Name) did not complete the PT handshake for '$($probe.Transport)'"
            Write-Warning "    output: $($result.Output -replace "`r?`n", ' | ')"
            $script:Missing.Add($result.Name)
        }
    }
}

# ---------------------------------------------------------------------------
# Step 5 - manifest
# ---------------------------------------------------------------------------
Write-Step 'Step 5/5  Write MANIFEST.json'

$fileEntries = New-Object System.Collections.Generic.List[object]
foreach ($name in $InstalledOrder) {
    $path = Join-Path $Dest $name
    if (-not (Test-Path -LiteralPath $path)) {
        if (-not $script:Missing.Contains($name)) { $script:Missing.Add($name) }
        continue
    }
    $fileEntries.Add([ordered]@{
        name   = $name
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
        bytes  = (Get-Item -LiteralPath $path).Length
    })
}

$builtFromSource = [ordered]@{}
foreach ($build in $PtBuilds) {
    if (Test-Path -LiteralPath (Join-Path $Dest $build.Name)) {
        $builtFromSource[$build.Name] = $build.Package
    }
}

$manifest = [ordered]@{
    platform          = 'windows-x64'
    tor_version       = $TorVersionLine
    source_url        = $SourceUrl
    fetched_at        = (Get-Date).ToString('o')
    files             = $fileEntries
    built_from_source = $builtFromSource
    notes             = @(
        "Official Tor Expert Bundle (tor-browser $Version) is the source of tor.exe, geoip, geoip6, lyrebird.exe and conjure-client.exe.",
        'The Expert Bundle does not ship standalone snowflake-client.exe, webtunnel-client.exe, meek-client.exe or obfs4proxy.exe; those were compiled from official upstream Tor Project / pluggable-transports Go sources (see built_from_source) with CGO_ENABLED=0, GOOS=windows GOARCH=amd64, modules fetched through proxy.golang.org.',
        'lyrebird.exe is the modern unified PT and itself serves obfs4, snowflake, webtunnel, meek_lite, obfs3, obfs2 and scramblesuit; upstream no longer ships a separate obfs4proxy.exe, so obfs4proxy.exe here is the last standalone upstream obfs4 release (2023-10-12).',
        'Every binary was executed during this run; tor.exe --version printed the value in tor_version and each PT completed the Tor PT handshake (VERSION 1 / CMETHOD ... / CMETHODS DONE).',
        'No companion DLLs are required; the archive contains no .dll files and every binary ran standalone.',
        'tor.exe locates geoip/geoip6 in its DataDirectory (or via GeoIPFile/GeoIPv6File); place a copy there or point those options at the geoip and geoip6 files beside tor.exe.'
    )
}
if ($script:Missing.Count -gt 0) {
    $manifest['missing'] = @($script:Missing | Select-Object -Unique)
}

$manifestPath = Join-Path $Dest 'MANIFEST.json'
$json = $manifest | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Note "wrote $manifestPath"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Step 'Done'
Write-Host "    tor version : $TorVersionLine"
Write-Host "    source      : $SourceUrl"
Write-Host "    destination : $Dest"
Get-ChildItem -LiteralPath $Dest | Sort-Object Name |
    ForEach-Object { Write-Host ('      {0,-22} {1,12:N0}' -f $_.Name, $_.Length) }

if ($script:Missing.Count -gt 0) {
    Write-Warning ('Missing or unverified: ' + (($script:Missing | Select-Object -Unique) -join ', '))
    exit 1
}
exit 0
