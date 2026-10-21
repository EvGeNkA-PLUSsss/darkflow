<#
.SYNOPSIS
    Verify the six Android arm64-v8a Tor pluggable-transport client binaries.

.DESCRIPTION
    Re-runnable acceptance check for android/app/src/main/jniLibs/arm64-v8a.
    For each of the six expected lib*.so files it asserts:

      1. the file exists and its size is plausible (> 1 MB and non-zero, so a
         truncated or stub link is caught);
      2. it is an ELF file - first four bytes are 7F 45 4C 46;
      3. ELF e_machine == 0xB7 (AArch64), read as a 2-byte little-endian field
         at offset 18;
      4. ELF e_type == 3 (ET_DYN), read as a 2-byte little-endian field at
         offset 16. With CGO_ENABLED=0 GOOS=android the Go linker emits a static
         PIE, and ET_DYN is exactly what makes the file an executable PIE that
         Android will accept;
      5. `go version -m <file>` succeeds and reports a module path/version.

    The script exits 0 only when every check passes for every binary, and it
    prints a summary table plus the raw `go version -m` provenance lines.

.PARAMETER GoExe
    Path to the go executable. Defaults to the Go 1.27.2 toolchain unpacked
    under %LOCALAPPDATA%\go-toolchain (the one the binaries were built with).

.PARAMETER Json
    Optional path. When given, the per-binary results are also written there as
    JSON, which is what PT_SOURCES.json is generated from.
#>
[CmdletBinding()]
param(
    [string] $GoExe,
    [string] $Json
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Dir      = Join-Path $RepoRoot 'android\app\src\main\jniLibs\arm64-v8a'

if (-not $GoExe) {
    $GoExe = Join-Path $env:LOCALAPPDATA 'go-toolchain\go1.27.2\go\bin\go.exe'
    if (-not (Test-Path -LiteralPath $GoExe)) {
        $GoExe = Join-Path $env:LOCALAPPDATA 'go-toolchain\go\bin\go.exe'
    }
}

# Output file -> the Go module it is expected to have been built from, plus the
# main package path recorded inside the binary.
#
# `go version -m` reports two different things and the distinction matters here:
#   path <P>   the main package's import path, i.e. the directory that was built
#   mod  <M> v<version>   the module that provides it
# For obfs4proxy, snowflake and webtunnel P is a subdirectory of M (e.g.
# M = gitlab.com/yawning/obfs4.git, P = gitlab.com/yawning/obfs4.git/obfs4proxy),
# so both are checked: M must equal the expected module and P must be M itself or
# beneath it. That is what proves the binary really came from the intended module
# rather than merely linking it as a dependency.
$Expected = [ordered]@{
    'liblyrebird.so' = @{
        Module = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird'
        Path   = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/cmd/lyrebird'
    }
    'libobfs4proxy.so' = @{
        Module = 'gitlab.com/yawning/obfs4.git'
        Path   = 'gitlab.com/yawning/obfs4.git/obfs4proxy'
    }
    'libsnowflake-client.so' = @{
        Module = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake/v2'
        Path   = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake/v2/client'
    }
    'libwebtunnel-client.so' = @{
        Module = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel'
        Path   = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel/main/client'
    }
    'libmeek-client.so' = @{
        Module = 'git.torproject.org/pluggable-transports/meek.git'
        Path   = 'git.torproject.org/pluggable-transports/meek.git/meek-client'
    }
    'libconjure-client.so' = @{
        Module = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/conjure'
        Path   = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/conjure/client'
    }
}

# Minimum plausible size for a Go binary that links net/http and crypto/tls.
$MinSize = 1MB

function Get-U16LE {
    param([byte[]] $Bytes, [int] $Offset)
    return [int]$Bytes[$Offset] + ([int]$Bytes[$Offset + 1] -shl 8)
}

Write-Host ''
Write-Host "Verifying Android arm64-v8a pluggable transports" -ForegroundColor Cyan
Write-Host "  directory : $Dir"
Write-Host "  go        : $GoExe"
if (Test-Path -LiteralPath $GoExe) {
    $goVersion = (& $GoExe version 2>&1 | Out-String).Trim()
    Write-Host "  toolchain : $goVersion"
} else {
    Write-Host "  toolchain : NOT FOUND - check 5 will be reported as failed" -ForegroundColor Yellow
}
Write-Host ''

$results = New-Object System.Collections.Generic.List[object]
$failed  = 0

foreach ($name in $Expected.Keys) {
    $path = Join-Path $Dir $name
    $expectedModule = $Expected[$name].Module
    $expectedPath   = $Expected[$name].Path

    $r = [ordered]@{
        file              = $name
        path              = $path
        expected_module   = $expectedModule
        expected_package  = $expectedPath
        exists            = $false
        size_bytes        = 0
        size_ok           = $false
        elf_magic         = $null
        is_elf            = $false
        e_machine         = $null
        e_machine_ok      = $false
        e_type            = $null
        e_type_ok         = $false
        go_version_m      = $null
        go_main_path      = $null
        go_module_path    = $null
        go_module_version = $null
        go_version_ok     = $false
        go_module_ok      = $false
        go_dep_count      = 0
        go_replacements   = @()
        go_replaced_anet  = $false
        pass              = $false
        notes             = @()
    }

    Write-Host "--- $name" -ForegroundColor White

    if (-not (Test-Path -LiteralPath $path)) {
        $r.notes += 'file missing'
        Write-Host '    [FAIL] file exists' -ForegroundColor Red
        $failed++
        $results.Add([pscustomobject]$r)
        continue
    }
    $r.exists = $true

    $item = Get-Item -LiteralPath $path
    $r.size_bytes = $item.Length
    $r.size_ok = ($item.Length -gt $MinSize)
    Write-Host ("    [{0}] size        {1,12:N0} bytes (> {2:N0} required)" -f $(if($r.size_ok){'PASS'}else{'FAIL'}), $item.Length, $MinSize) -ForegroundColor $(if($r.size_ok){'Green'}else{'Red'})
    if (-not $r.size_ok) { $r.notes += "size $($item.Length) below minimum" }

    # Read enough of the header for magic + e_type + e_machine.
    $fs = [System.IO.File]::OpenRead($path)
    try {
        $hdr = New-Object byte[] 20
        $read = $fs.Read($hdr, 0, 20)
    } finally { $fs.Dispose() }

    if ($read -lt 20) {
        $r.notes += "only $read bytes readable"
        Write-Host '    [FAIL] ELF header could not be read' -ForegroundColor Red
    }

    $magic = ($hdr[0..3] | ForEach-Object { $_.ToString('X2') }) -join ' '
    $r.elf_magic = $magic
    $r.is_elf = ($hdr[0] -eq 0x7F -and $hdr[1] -eq 0x45 -and $hdr[2] -eq 0x4C -and $hdr[3] -eq 0x46)
    Write-Host ("    [{0}] ELF magic   {1}" -f $(if($r.is_elf){'PASS'}else{'FAIL'}), $magic) -ForegroundColor $(if($r.is_elf){'Green'}else{'Red'})
    if (-not $r.is_elf) { $r.notes += "magic was $magic" }

    $r.e_machine = Get-U16LE -Bytes $hdr -Offset 18
    $r.e_machine_ok = ($r.e_machine -eq 0xB7)
    Write-Host ("    [{0}] e_machine   0x{1:X} (0xB7 = AArch64)" -f $(if($r.e_machine_ok){'PASS'}else{'FAIL'}), $r.e_machine) -ForegroundColor $(if($r.e_machine_ok){'Green'}else{'Red'})
    if (-not $r.e_machine_ok) { $r.notes += "e_machine 0x$('{0:X}' -f $r.e_machine) is not AArch64" }

    $r.e_type = Get-U16LE -Bytes $hdr -Offset 16
    $r.e_type_ok = ($r.e_type -eq 3)
    Write-Host ("    [{0}] e_type      {1} (3 = ET_DYN / PIE)" -f $(if($r.e_type_ok){'PASS'}else{'FAIL'}), $r.e_type) -ForegroundColor $(if($r.e_type_ok){'Green'}else{'Red'})
    if (-not $r.e_type_ok) { $r.notes += "e_type $($r.e_type) is not ET_DYN" }

    # go version -m
    if (Test-Path -LiteralPath $GoExe) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $gv = (& $GoExe version -m $path 2>&1 | Out-String)
        $gvCode = $LASTEXITCODE
        $ErrorActionPreference = $prev
        $gv = $gv.Trim()
        $r.go_version_m = $gv
        $r.go_version_ok = ($gvCode -eq 0 -and $gv.Length -gt 0)

        if ($r.go_version_ok) {
            $lines = $gv -split "`r?`n"

            # main package path
            $pathLine = ($lines | Where-Object { $_ -match '^\s*path\s+\S' } | Select-Object -First 1)
            if ($pathLine) { $r.go_main_path = ($pathLine.Trim() -split '\s+')[1] }

            # providing module: first "mod <path> <version>" at top level
            $modLine = ($lines | Where-Object { $_ -match '^\s*mod\s+\S' } | Select-Object -First 1)
            if ($modLine) {
                $parts = ($modLine.Trim() -split '\s+')
                $r.go_module_path = $parts[1]
                $r.go_module_version = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            }

            $r.go_dep_count = @($lines | Where-Object { $_ -match '^\s*dep\s+\S' }).Count
            $r.go_replacements = @($lines | Where-Object { $_ -match '^\s*=>\s+\S' } | ForEach-Object { $_.Trim() })
            $r.go_replaced_anet = [bool](@($lines | Where-Object { $_ -match 'wlynxg/anet' -or $_ -match 'anet-shim' }).Count -gt 0)

            # The binary came from the expected module if its providing module is
            # that module AND the main package sits at or beneath it.
            $moduleMatch = ($r.go_module_path -eq $expectedModule)
            $pathMatch   = ($r.go_main_path -eq $expectedPath)
            $r.go_module_ok = ($moduleMatch -and $pathMatch)

            Write-Host ("    [{0}] go version  {1}" -f $(if($r.go_version_ok){'PASS'}else{'FAIL'}), $lines[0]) -ForegroundColor $(if($r.go_version_ok){'Green'}else{'Red'})
            Write-Host ("    [{0}] mod         {1} @ {2}" -f $(if($moduleMatch){'PASS'}else{'FAIL'}), $r.go_module_path, $r.go_module_version) -ForegroundColor $(if($moduleMatch){'Green'}else{'Red'})
            Write-Host ("    [{0}] path        {1}" -f $(if($pathMatch){'PASS'}else{'FAIL'}), $r.go_main_path) -ForegroundColor $(if($pathMatch){'Green'}else{'Red'})
            Write-Host ("          deps {0}, replacements {1}" -f $r.go_dep_count, $r.go_replacements.Count) -ForegroundColor DarkGray
            foreach ($rep in $r.go_replacements) {
                Write-Host ("          replace {0}" -f ($rep -replace '^\s*=>\s*','' )) -ForegroundColor DarkGray
            }
            if (-not $moduleMatch) { $r.notes += "module '$($r.go_module_path)' does not match expected '$expectedModule'" }
            if (-not $pathMatch)   { $r.notes += "main path '$($r.go_main_path)' does not match expected '$expectedPath'" }
        } else {
            Write-Host "    [FAIL] go version -m (exit $gvCode): $gv" -ForegroundColor Red
            $r.notes += "go version -m failed: $gv"
        }
    } else {
        $r.notes += 'go toolchain unavailable for go version -m'
        Write-Host '    [FAIL] go version -m (no go toolchain)' -ForegroundColor Red
    }

    $r.pass = ($r.exists -and $r.size_ok -and $r.is_elf -and $r.e_machine_ok -and $r.e_type_ok -and $r.go_version_ok -and $r.go_module_ok)
    if (-not $r.pass) { $failed++ }
    Write-Host ("    => {0}" -f $(if($r.pass){'PASS'}else{'FAIL'})) -ForegroundColor $(if($r.pass){'Green'}else{'Red'})
    Write-Host ''
    $results.Add([pscustomobject]$r)
}

# --- summary ---------------------------------------------------------------
Write-Host '=== SUMMARY ===' -ForegroundColor Cyan
$results |
    Select-Object file,
        @{n='size';e={ '{0:N0}' -f $_.size_bytes }},
        @{n='ELF';e={ if($_.is_elf){'yes'}else{'NO'} }},
        @{n='e_machine';e={ if($null -eq $_.e_machine){'-'}else{ '0x{0:X}' -f $_.e_machine } }},
        @{n='e_type';e={ $_.e_type }},
        @{n='main package';e={ $_.go_main_path }},
        @{n='module version';e={ $_.go_module_version }},
        @{n='anet shim';e={ if($_.go_replaced_anet){'yes'}else{'no'} }},
        @{n='result';e={ if($_.pass){'PASS'}else{'FAIL'} }} |
    Format-Table -AutoSize | Out-String -Width 500 | Write-Host

$total = ($results | Measure-Object -Property size_bytes -Sum).Sum
Write-Host ("Total native payload: {0:N0} bytes ({1:N2} MB)" -f $total, ($total / 1MB))
$passed = ($results | Where-Object { $_.pass }).Count
Write-Host ("Result: {0}/{1} binaries passed all checks" -f $passed, $results.Count) -ForegroundColor $(if($failed -eq 0){'Green'}else{'Red'})
Write-Host ''

Write-Host '=== go version -m (verbatim) ===' -ForegroundColor Cyan
foreach ($r in $results) {
    Write-Host "--- $($r.file)" -ForegroundColor White
    if ($r.go_version_m) { Write-Host $r.go_version_m } else { Write-Host '    (unavailable)' }
    Write-Host ''
}

if ($Json) {
    $payload = [ordered]@{
        generated_at_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        go_toolchain     = $goVersion
        directory        = $Dir
        total_bytes      = $total
        passed           = $passed
        total            = $results.Count
        binaries         = $results
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Json -Encoding UTF8
    Write-Host "JSON written to $Json" -ForegroundColor Cyan
}

if ($failed -gt 0) { exit 1 }
exit 0
