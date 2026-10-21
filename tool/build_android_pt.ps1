<#
.SYNOPSIS
    Build the six Tor pluggable-transport CLIENT binaries for Android arm64-v8a.

.DESCRIPTION
    Cross-compiles each PT client with GOOS=android GOARCH=arm64 CGO_ENABLED=0 and
    writes it into android/app/src/main/jniLibs/arm64-v8a under a lib*.so name.

    Two naming rules drive the output names:
      * Android only extracts files matching lib*.so from the APK's lib/<abi>/
        directory, so a plain "lyrebird" would never be installed;
      * since API 29 (W^X) only files inside the app's native-library directory
        may be exec'd, so the PT must live in jniLibs and be exec'd in place.

    With CGO_ENABLED=0 and GOOS=android the Go linker emits a static PIE
    (ET_DYN) executable, which is what Android accepts. GOOS=linux is NOT used:
    it produces a non-PIE binary Android refuses to exec.

    Modules live on gitlab.torproject.org / git.torproject.org, whose HTTPS is
    blocked from this network, so every module is fetched through the Go module
    proxy (proxy.golang.org) rather than cloned. GOPROXY deliberately carries no
    ",direct" fallback: a fallback would attempt the blocked origin and turn a
    clean "the proxy does not have it" error into a network timeout.

    HOW EACH PACKAGE IS BUILT - and why not `go install`:

      `go install pkg@version` is the obvious tool and fails here for two
      independent reasons:
        1. it refuses to cross-compile at all, with
           "go: cannot install cross-compiled binaries when GOBIN is set";
        2. for any module whose go.mod carries a `replace` directive (the Tor
           Conjure client module does) it refuses with "The go.mod file for the
           module providing named packages contains one or more replace
           directives."
      `go build -o file pkg@version` is not an alternative either: `go build`
      has no path@version form at all ("can only use path@version syntax with
      'go get' and 'go install' in module-aware mode").

      So each package is built inside a throwaway module created per target:
          go mod init ptbuild.local/stage     (in a scratch dir)
          go get    <package>@<version>       (resolves + records the version)
          go build -o <staged file> <package>
      The scratch modules live under the toolchain cache, never in the Flutter
      repository.

    The Go toolchains are unpacked under %LOCALAPPDATA%\go-toolchain and are
    invoked by full path. Nothing is installed system-wide and PATH is untouched.
#>
[CmdletBinding()]
param(
    # Build only the named output files (default: all six).
    [string[]] $Only,

    # Toolchain directory name under %LOCALAPPDATA%\go-toolchain (the folder that
    # contains go\bin\go.exe). Defaults to go1.27.2.
    [string] $ToolchainDir = 'go1.27.2',

    # Where to write the built binaries. Defaults to the real jniLibs directory.
    [string] $OutDir
)

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$JniLibsDir = if ($OutDir) { $OutDir } else { Join-Path $RepoRoot 'android\app\src\main\jniLibs\arm64-v8a' }
$ToolRoot   = Join-Path $env:LOCALAPPDATA 'go-toolchain'
$CacheRoot  = Join-Path $ToolRoot 'cache'
$Scratch    = Join-Path $CacheRoot 'scratch'
$LogDir     = Join-Path $CacheRoot 'logs'

# Go 1.27.2 is the default toolchain. lyrebird's go.mod declares "go 1.26.0" and
# snowflake's declares "go 1.25.12", which go1.23.4 refuses outright:
#     requires go >= 1.26.0 (running go 1.23.4; GOTOOLCHAIN=local)
# A single newer toolchain serves all six; its language version is backward
# compatible with the older modules.
$GoExe = Join-Path $ToolRoot "$ToolchainDir\go\bin\go.exe"

# ---------------------------------------------------------------------------
# The six builds.
#
# Two package paths need a note, because they do not follow the obvious layout:
#
#   * lyrebird is a multi-module repository. The client main package is the
#     NESTED module .../lyrebird/cmd/lyrebird (the module root has no main
#     package), so the nested module path is what the proxy is asked for.
#
#   * github.com/refraction-networking/conjure has NO client command: its cmd/
#     directory holds only the station-side `application` and
#     `registration-server`, and `cmd/conjure-client` has never existed anywhere
#     in that repository's history. The Tor Conjure *client* PT is a separate
#     module, gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/
#     conjure, whose ./client package is the client main (it calls
#     pt.ClientSetup and serves the "conjure" managed transport). That module is
#     what is built here.
# ---------------------------------------------------------------------------
# Upstream github.com/wlynxg/anet v0.0.5 reaches into the standard library with
# //go:linkname net.zoneCache, which the Go linker rejects for Android/arm64 on
# every toolchain that can build these clients:
#     link: github.com/wlynxg/anet: invalid reference to net.zoneCache
# It is an indirect dependency (via the pion WebRTC stack), so the only way to
# build snowflake / lyrebird / conjure is to redirect the import path to the
# reviewed local shim in tool\anet-shim, which implements the same API on top of
# the standard library's net package.
$AnetShimPath = Join-Path $RepoRoot 'tool\anet-shim'
if (-not (Test-Path -LiteralPath $AnetShimPath)) { throw "anet shim not found at $AnetShimPath" }
$AnetReplace = "github.com/wlynxg/anet=$AnetShimPath"

$Builds = @(
    @{ Output  = 'liblyrebird.so'
       Package = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/cmd/lyrebird'
       Version = 'latest'
       Module  = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/cmd/lyrebird'
       Note    = 'multi-module repo; the nested module .../lyrebird/cmd/lyrebird is the client main'
       Replaces = @($AnetReplace) },

    @{ Output  = 'libobfs4proxy.so'
       Package = 'gitlab.com/yawning/obfs4.git/obfs4proxy'
       Version = 'v0.0.0-20231012084234-c3e2d44b1033'
       Module  = 'gitlab.com/yawning/obfs4.git/obfs4proxy'
       Note    = ''
       Replaces = @() },

    @{ Output  = 'libsnowflake-client.so'
       Package = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake/v2/client'
       Version = 'v2.15.1'
       Module  = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake/v2/client'
       Note    = ''
       Replaces = @($AnetReplace) },

    @{ Output  = 'libwebtunnel-client.so'
       Package = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel/main/client'
       Version = 'v0.0.7'
       Module  = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel/main/client'
       Note    = ''
       Replaces = @() },

    @{ Output  = 'libmeek-client.so'
       Package = 'git.torproject.org/pluggable-transports/meek.git/meek-client'
       Version = 'v0.38.0'
       Module  = 'git.torproject.org/pluggable-transports/meek.git/meek-client'
       Note    = ''
       Replaces = @() },

    @{ Output  = 'libconjure-client.so'
       Package = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/conjure/client'
       Version = 'latest'
       Module  = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/conjure'
       Note    = 'refraction-networking/conjure has no client cmd; the Tor Conjure PT client module is used instead'
       # The Tor Conjure module's own go.mod carries these two `replace`
       # directives, and they are load-bearing: without the first, conjure's
       # pkg/dtls does not compile against stock pion/dtls (it needs the
       # mingyech fork's CustomClientHelloRandom / RemoteRandomBytes), and
       # without the second it resolves the station revision instead of the
       # client one. A `replace` in a dependency's go.mod does not apply when
       # that module is a dependency, so both are replayed into the scratch
       # module - which is what the module's authors intended.
       Replaces = @(
           $AnetReplace
           'github.com/pion/dtls/v2=github.com/mingyech/dtls/v2@v2.0.0'
           'github.com/refraction-networking/conjure@v0.7.11=github.com/refraction-networking/conjure@v0.7.12-0.20250507182851-8676ab6282b8'
       ) }
)

foreach ($d in @($JniLibsDir, $CacheRoot, $Scratch, $LogDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

if (-not (Test-Path -LiteralPath $GoExe)) { throw "Go toolchain not found at $GoExe" }

# --- build environment -----------------------------------------------------
# Every path is redirected into the toolchain scratch area so the Flutter
# repository itself stays clean: only the six .so files and the provenance
# record are written into it.
$env:GOROOT      = Split-Path -Parent (Split-Path -Parent $GoExe)
$env:GOPATH      = Join-Path $CacheRoot 'gopath'
$env:GOCACHE     = Join-Path $CacheRoot 'gocache'
$env:GOMODCACHE  = Join-Path $CacheRoot 'gomodcache'
$env:GOPROXY     = 'https://proxy.golang.org'   # no ",direct": torproject.org is blocked
$env:GOSUMDB     = 'off'
$env:GOTOOLCHAIN = 'local'                      # never fetch another toolchain mid-build
$env:GOFLAGS     = '-mod=mod -trimpath'
$env:CGO_ENABLED = '0'
$env:GOOS        = 'android'
$env:GOARCH      = 'arm64'
Remove-Item Env:GOBIN -ErrorAction SilentlyContinue   # irrelevant for `go build -o`

New-Item -ItemType Directory -Force -Path $env:GOPATH, $env:GOCACHE, $env:GOMODCACHE | Out-Null

function Invoke-Go {
    <#
        Runs go.exe with output redirected to files.

        Native commands write progress ("go: downloading ...") to stderr, and
        Windows PowerShell 5.1 turns anything a native command writes to stderr
        into an ErrorRecord even on success. Redirecting the two streams to files
        through Start-Process sidesteps that entirely and still gives a reliable
        exit code.
    #>
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string]   $Tag,
        [Parameter(Mandatory)] [string]   $WorkDir
    )
    $o = Join-Path $LogDir "$Tag.out.txt"
    $e = Join-Path $LogDir "$Tag.err.txt"
    Remove-Item -LiteralPath $o, $e -ErrorAction SilentlyContinue

    $p = Start-Process -FilePath $GoExe -ArgumentList $Arguments -WorkingDirectory $WorkDir `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e

    $text = ''
    foreach ($f in @($o, $e)) { if (Test-Path -LiteralPath $f) { $text += (Get-Content -LiteralPath $f -Raw) } }
    return [pscustomobject]@{ Exit = $p.ExitCode; Output = $text }
}

Write-Host "Go toolchain : $GoExe" -ForegroundColor Cyan
& $GoExe version
Write-Host "Target       : GOOS=$env:GOOS GOARCH=$env:GOARCH CGO_ENABLED=$env:CGO_ENABLED" -ForegroundColor Cyan
Write-Host "Build flags  : $env:GOFLAGS" -ForegroundColor Cyan
Write-Host "Output dir   : $JniLibsDir" -ForegroundColor Cyan
Write-Host ''

$Results = @()
$Failed  = @()

foreach ($b in $Builds) {
    if ($Only -and ($Only -notcontains $b.Output)) { continue }

    Write-Host "=== $($b.Output)  <-  $($b.Package)@$($b.Version)" -ForegroundColor Cyan
    $stem = $b.Output -replace '\.so$', ''

    # One throwaway module per target, under the toolchain cache.
    $work = Join-Path $Scratch "stage-$stem"
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    Set-Content -LiteralPath (Join-Path $work 'main.go') -Value "package main`r`n`r`nfunc main() {}" -Encoding UTF8

    # 1. scratch module
    $r = Invoke-Go -Arguments @('mod', 'init', 'ptbuild.local/stage') -Tag "$stem.init" -WorkDir $work
    if ($r.Exit -ne 0) {
        Write-Host "    FAILED at 'go mod init' (exit $($r.Exit))" -ForegroundColor Red
        Write-Host "    $($r.Output.Trim())" -ForegroundColor DarkRed
        $Failed += [pscustomobject]@{ Output = $b.Output; Package = $b.Package; Stage = 'mod init'; Error = $r.Output.Trim() }
        continue
    }

    # 2. resolve and record the requested version (this is the step that talks to
    #    the module proxy and that `go build` cannot do on its own).
    $r = Invoke-Go -Arguments @('get', "$($b.Package)@$($b.Version)") -Tag "$stem.get" -WorkDir $work
    if ($r.Exit -ne 0) {
        Write-Host "    FAILED at 'go get $($b.Package)@$($b.Version)' (exit $($r.Exit))" -ForegroundColor Red
        ($r.Output.Trim() -split "`r?`n" | Select-Object -Last 12) | ForEach-Object { Write-Host "    | $_" -ForegroundColor DarkRed }
        $Failed += [pscustomobject]@{ Output = $b.Output; Package = $b.Package; Stage = "go get $($b.Version)"; Error = $r.Output.Trim() }
        continue
    }

    # 3. replay any `replace` directives this target needs (see the table above:
    #    the anet shim, and the Tor Conjure module's own two directives).
    $replaceFailed = $false
    foreach ($rep in @($b.Replaces)) {
        if (-not $rep) { continue }
        $r = Invoke-Go -Arguments @('mod', 'edit', '-replace', $rep) -Tag "$stem.replace" -WorkDir $work
        if ($r.Exit -ne 0) {
            Write-Host "    FAILED at 'go mod edit -replace $rep' (exit $($r.Exit))" -ForegroundColor Red
            Write-Host "    $($r.Output.Trim())" -ForegroundColor DarkRed
            $Failed += [pscustomobject]@{ Output = $b.Output; Package = $b.Package; Stage = "go mod edit -replace $rep"; Error = $r.Output.Trim() }
            $replaceFailed = $true
            break
        }
        Write-Host "    replace: $rep" -ForegroundColor DarkGray
    }
    if ($replaceFailed) { continue }

    # 4. cross-compile
    $tagged = Join-Path $work $b.Output
    $r = Invoke-Go -Arguments @('build', '-o', $tagged, $b.Package) -Tag "$stem.build" -WorkDir $work
    if ($r.Exit -ne 0 -or -not (Test-Path -LiteralPath $tagged)) {
        Write-Host "    FAILED at 'go build' (exit $($r.Exit))" -ForegroundColor Red
        ($r.Output.Trim() -split "`r?`n" | Select-Object -Last 25) | ForEach-Object { Write-Host "    | $_" -ForegroundColor DarkRed }
        $Failed += [pscustomobject]@{ Output = $b.Output; Package = $b.Package; Stage = 'go build'; Error = $r.Output.Trim() }
        continue
    }

    $dest = Join-Path $JniLibsDir $b.Output
    Copy-Item -LiteralPath $tagged -Destination $dest -Force
    $len = (Get-Item -LiteralPath $dest).Length
    Write-Host ("    OK  {0}  {1:N0} bytes" -f $b.Output, $len) -ForegroundColor Green
    $Results += [pscustomobject]@{ Output = $b.Output; Package = $b.Package; Bytes = $len }
}

Write-Host ''
if ($Failed.Count -gt 0) {
    Write-Host "=== FAILURES ($($Failed.Count)) ===" -ForegroundColor Red
    foreach ($f in $Failed) {
        Write-Host "  $($f.Output)  <-  $($f.Package)" -ForegroundColor Red
        Write-Host "  at $($f.Stage):" -ForegroundColor DarkRed
        Write-Host "  $($f.Error)" -ForegroundColor DarkRed
        Write-Host ''
    }
    exit 1
}
Write-Host "All requested binaries built ($($Results.Count))." -ForegroundColor Green
exit 0
