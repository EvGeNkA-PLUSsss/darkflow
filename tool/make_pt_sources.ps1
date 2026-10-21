<#
.SYNOPSIS
    Write jniLibs/PT_SOURCES.json - the provenance record for the six Android
    arm64-v8a pluggable-transport binaries.

.DESCRIPTION
    These binaries are fetched, not reviewed, so what they are has to be written
    down. This script reads the raw verification JSON produced by
    verify_android_pt.ps1 -Json and joins it with the declared provenance of each
    build (module, version, main package, build command, any deliberate
    substitutions) to emit PT_SOURCES.json.

    It also hashes each binary in full, so a later reader can tell whether the
    file in jniLibs is the same artefact this record describes.
#>
[CmdletBinding()]
param(
    [string] $VerifyJson = (Join-Path (Split-Path -Parent $PSScriptRoot) 'android\app\src\main\jniLibs\arm64-v8a\verify_raw.json'),
    [string] $OutJson
)

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$JniLibsDir = Join-Path $RepoRoot 'android\app\src\main\jniLibs\arm64-v8a'
if (-not $OutJson) { $OutJson = Join-Path $JniLibsDir 'PT_SOURCES.json' }

if (-not (Test-Path -LiteralPath $VerifyJson)) {
    throw "Verification JSON not found at $VerifyJson - run verify_android_pt.ps1 -Json <path> first."
}
$verify = Get-Content -LiteralPath $VerifyJson -Raw | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Declared provenance per artefact. Everything here was determined by inspecting
# the upstream modules, not assumed.
# ---------------------------------------------------------------------------
$AnetShim = @{
    module        = 'github.com/wlynxg/anet'
    version       = 'v0.0.5 (redirected)'
    kind          = 'local source substitute'
    path          = 'tool/anet-shim'
    reason        = 'Upstream anet v0.0.5 links against the unexported standard-library symbol net.zoneCache via //go:linkname, which the Go linker rejects: "link: github.com/wlynxg/anet: invalid reference to net.zoneCache". Reproduced for GOOS=android/GOARCH=arm64 with go1.23.4, go1.25.12 and go1.27.2. snowflake needs go >= 1.25.12 and lyrebird needs go >= 1.26.0, so no toolchain that can build these clients avoids it, and there is no build tag that selects anet''s non-Android pass-through file when the target is Android. The shim keeps the same import path and exported API but implements it on top of the standard library net package, which is exactly what upstream anet itself does on every non-Android platform.'
    api_surface   = 'Interfaces, InterfaceAddrs, InterfaceAddrsByInterface, SetAndroidVersion (plus the netlink RIB helpers). The only callers in these binaries are github.com/pion/transport/{v2,v3,v4}/stdnet, which use Interfaces and InterfaceAddrsByInterface.'
    consequence   = 'anet''s Android netlink workaround is NOT present. Interface enumeration uses the standard library getifaddrs path instead. This is the one functional deviation in this build set.'
}

$Provenance = [ordered]@{
    'liblyrebird.so' = @{
        transport     = 'lyrebird (unified client: obfs4, snowflake, webtunnel, meek_lite, obfs3, obfs2, scramblesuit)'
        module        = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird'
        main_package  = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/cmd/lyrebird'
        requested     = '@latest'
        build_command = 'go get <pkg>@latest; go mod edit -replace github.com/wlynxg/anet=<tool/anet-shim>; go build -o liblyrebird.so <pkg>'
        notes         = 'lyrebird is a multi-module repository. The module root has no main package; the client main lives in the nested module .../lyrebird/cmd/lyrebird, so that nested module path is what was requested. Its go.mod declares "go 1.26.0" and its "latest" tag is a pseudo-version because upstream publishes no semver tags. This is the only binary whose resolved version is not pinned by the request: @latest resolved to the commit above and will move if upstream publishes a new commit.'
        substitutions = @($AnetShim)
    }
    'libobfs4proxy.so' = @{
        transport     = 'obfs4'
        module        = 'gitlab.com/yawning/obfs4.git'
        main_package  = 'gitlab.com/yawning/obfs4.git/obfs4proxy'
        requested     = 'v0.0.0-20231012084234-c3e2d44b1033'
        build_command = 'go get gitlab.com/yawning/obfs4.git/obfs4proxy@v0.0.0-20231012084234-c3e2d44b1033; go build -o libobfs4proxy.so <pkg>'
        notes         = 'The last standalone upstream obfs4proxy release (2023-10-12); upstream obfs4proxy is superseded by lyrebird. No source modifications.'
        substitutions = @()
    }
    'libsnowflake-client.so' = @{
        transport     = 'snowflake'
        module        = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake/v2'
        main_package  = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake/v2/client'
        requested     = 'v2.15.1'
        build_command = 'go get <pkg>@v2.15.1; go mod edit -replace github.com/wlynxg/anet=<tool/anet-shim>; go build -o libsnowflake-client.so <pkg>'
        notes         = 'The module path requested (snowflake/v2/client) resolves to the parent module snowflake/v2; the client package sits in its client/ subdirectory, which is what the path line reports. Its go.mod declares "go 1.25.12".'
        substitutions = @($AnetShim)
    }
    'libwebtunnel-client.so' = @{
        transport     = 'webtunnel'
        module        = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel'
        main_package  = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel/main/client'
        requested     = 'v0.0.7'
        build_command = 'go get <pkg>@v0.0.7; go build -o libwebtunnel-client.so <pkg>'
        notes         = 'The requested module path (webtunnel/main/client) resolves to the parent module webtunnel; the main package is main/client. No source modifications.'
        substitutions = @()
    }
    'libmeek-client.so' = @{
        transport     = 'meek_lite (meek)'
        module        = 'git.torproject.org/pluggable-transports/meek.git'
        main_package  = 'git.torproject.org/pluggable-transports/meek.git/meek-client'
        requested     = 'v0.38.0'
        build_command = 'go get git.torproject.org/pluggable-transports/meek.git/meek-client@v0.38.0; go build -o libmeek-client.so <pkg>'
        notes         = 'The requested module path (meek-client) resolves to the parent module meek.git. No source modifications.'
        substitutions = @()
    }
    'libconjure-client.so' = @{
        transport     = 'conjure'
        module        = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/conjure'
        main_package  = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/conjure/client'
        requested     = '@latest'
        build_command = 'go get <pkg>@latest; go mod edit -replace github.com/wlynxg/anet=<tool/anet-shim>; go mod edit -replace github.com/pion/dtls/v2=github.com/mingyech/dtls/v2@v2.0.0; go mod edit -replace github.com/refraction-networking/conjure@v0.7.11=github.com/refraction-networking/conjure@v0.7.12-0.20250507182851-8676ab6282b8; go build -o libconjure-client.so <pkg>'
        notes         = 'DEVIATION FROM THE REQUESTED MODULE PATH. The request named github.com/refraction-networking/conjure and suggested ./cmd/conjure-client. That repository has no client command: its cmd/ directory contains only the station-side cmd/application and cmd/registration-server, and the path cmd/conjure-client has never existed in its history. Its only package main files are four test/example programs (pkg/dtls/examples/{dial,listen}, pkg/registrars/dns-registrar/examples/{client,server}), none of which is the client PT. The actual Tor Conjure client pluggable transport is a separate module, gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/conjure, whose client/conjure.go is package main, calls pt.ClientSetup, serves the "conjure" managed transport and honours TOR_PT_EXIT_ON_STDIN_CLOSE - i.e. it is the client binary Tor invokes. That module was built instead. It also depends on github.com/refraction-networking/conjure v0.9.1 as a library.'
        substitutions = @(
            $AnetShim
            @{
                module   = 'github.com/pion/dtls/v2'
                version  = 'v2.2.12 => github.com/mingyech/dtls/v2 v2.0.0'
                kind     = 'replace replayed from the upstream module go.mod'
                reason   = 'The Tor Conjure module go.mod declares this replace and it is load-bearing: without it conjure/pkg/dtls does not compile against stock pion/dtls (unknown field CustomClientHelloRandom, undefined RemoteRandomBytes/RandomBytes). A replace directive in a dependency''s go.mod does not take effect when that module is a dependency, so it is replayed into the build module - which is what the module''s authors intended.'
            }
            @{
                module   = 'github.com/refraction-networking/conjure'
                version  = 'v0.7.11 => v0.7.12-0.20250507182851-8676ab6282b8'
                kind     = 'replace replayed from the upstream module go.mod'
                reason   = 'Also declared by the Tor Conjure module go.mod. Without it the library resolves to the station revision rather than the client revision the module asks for. The proxy does not offer v0.7.11, so this replacement is required for resolution to succeed at all.'
            }
        )
    }
}

$gvToolchain = $verify.go_toolchain

$binaries = @()
$totalBytes = 0
foreach ($v in $verify.binaries) {
    $name = $v.file
    $prov = $Provenance[$name]
    $full = Join-Path $JniLibsDir $name
    $size = (Get-Item -LiteralPath $full).Length
    $sha  = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
    $totalBytes += $size

    # version line taken verbatim from `go version -m`
    $versionLine = ($v.go_version_m -split "`r?`n" | Where-Object { $_ -match '^\s*mod\s+\S' } | Select-Object -First 1)
    if ($versionLine) { $versionLine = $versionLine.Trim() } 

    $binaries += [ordered]@{
        artifact            = $name
        transport           = $prov.transport
        go_module           = $v.go_module_path
        main_package        = $v.go_main_path
        resolved_version    = $v.go_module_version
        requested_version   = $prov.requested
        build_command       = $prov.build_command
        file_size_bytes     = $size
        sha256              = $sha
        elf_is_elf          = $v.is_elf
        elf_e_machine       = ('0x{0:X}' -f $v.e_machine)
        elf_e_machine_ok    = $v.e_machine_ok
        elf_e_type          = $v.e_type
        elf_e_type_ok       = $v.e_type_ok
        go_version_line     = $versionLine
        go_dependency_count = $v.go_dep_count
        go_replacements     = @($v.go_replacements)
        uses_anet_shim      = $v.go_replaced_anet
        verification        = if ($v.pass) { 'PASS' } else { 'FAIL' }
        notes               = $prov.notes
        substitutions       = @($prov.substitutions)
    }
}

$doc = [ordered]@{
    schema_version = 1
    description    = 'Provenance record for the Tor pluggable-transport CLIENT binaries shipped in android/app/src/main/jniLibs/arm64-v8a. These binaries are fetched and compiled from upstream sources, not reviewed by hand, so this file records what each one is and how it was produced.'
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    disclaimer     = 'REVIEW REQUIRED. These are third-party upstream Go modules compiled for Android arm64-v8a. They were not source-audited. Two build-time substitutions were necessary and are recorded per artefact: a local replacement for github.com/wlynxg/anet (tool/anet-shim) and, for the conjure client, two replace directives replayed from that module''s own go.mod.'
    target = [ordered]@{
        goos          = 'android'
        goarch        = 'arm64'
        abi_directory = 'arm64-v8a'
        cgo_enabled   = $false
        elf_type      = 'ET_DYN (static PIE, required by Android)'
        e_machine     = '0xB7 (AArch64)'
        rationale     = 'Files must be named lib*.so and live in the APK native-library directory: Android only extracts lib*.so from lib/<abi>/, and since API 29 (W^X) only files in that directory may be exec''d. CGO_ENABLED=0 with GOOS=android makes the Go linker emit a static PIE. GOOS=linux was not used because it produces a non-PIE binary Android refuses to execute.'
    }
    toolchain = [ordered]@{
        go_version                = $gvToolchain
        go_root                   = '%LOCALAPPDATA%\go-toolchain\go1.27.2'
        other_toolchains_installed = @('go1.23.4', 'go1.25.12')
        why_1_27_2                = 'A single toolchain was used for all six. go1.23.4 is too old (lyrebird requires go >= 1.26.0, snowflake >= 1.25.12). go1.25.12 and go1.27.2 both work once the anet shim is in place; go1.27.2 was chosen as the newest installed.'
        goflags                   = '-mod=mod -trimpath'
        goproxy                   = 'https://proxy.golang.org (no ",direct" fallback: gitlab.torproject.org and git.torproject.org HTTPS are blocked on this network, and a fallback would turn a clean proxy error into a network timeout)'
        method                    = 'Each package was built inside a throwaway module in the toolchain cache: go mod init, go get <package>@<version>, optional go mod edit -replace, then go build -o <file> <package>. `go install pkg@version` cannot be used: it refuses to cross-compile ("go: cannot install cross-compiled binaries when GOBIN is set") and rejects modules carrying replace directives ("The go.mod file for the module providing named packages contains one or more replace directives"). `go build pkg@version` is not an option either - go build has no path@version form.'
    }
    summary = [ordered]@{
        requested_count = 6
        built_count     = @($binaries | Where-Object { $_.verification -eq 'PASS' }).Count
        failed_count    = @($binaries | Where-Object { $_.verification -ne 'PASS' }).Count
        total_bytes     = $totalBytes
        total_mib       = [math]::Round($totalBytes / 1MB, 2)
    }
    verification = [ordered]@{
        script  = 'tool/verify_android_pt.ps1'
        checks  = @(
            'file exists and size > 1 MiB (a Go HTTP binary far below that is suspicious)',
            'first four bytes are 7F 45 4C 46 (ELF)',
            'ELF e_machine at offset 18 (2-byte little-endian) == 0xB7 (AArch64)',
            'ELF e_type at offset 16 (2-byte little-endian) == 3 (ET_DYN, i.e. PIE)',
            'go version -m succeeds and reports the expected module and main package'
        )
        result  = ('{0}/{1} passed' -f @($binaries | Where-Object { $_.verification -eq 'PASS' }).Count, $binaries.Count)
        raw_json = 'verify_raw.json'
    }
    binaries = $binaries
}

$doc | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutJson -Encoding UTF8
Write-Host "Wrote $OutJson" -ForegroundColor Green
Write-Host ("  {0} binaries, {1:N0} bytes total ({2:N2} MiB)" -f $binaries.Count, $totalBytes, ($totalBytes / 1MB))
