# Creates a GitHub release and uploads the artifacts.
#
#   pwsh -File tool/create_release.ps1 -Version v0.1.0
#
# ## Two things that are written this way because they went wrong once
#
#   * **`Get-Content` without `-Encoding UTF8`** reads a BOM-less UTF-8 file as ANSI, so
#     every dash and section sign in the notes arrives mangled at GitHub. The body is read
#     with .NET instead.
#   * **`"$base?name=..."`** is not safe in PowerShell: the `?` is parsed as part of the
#     variable name, so the string collapses to just the query and the request fails with
#     "cannot parse hostname". Braces around the variable, or concatenation, are required.
#
# A `-Raw` read is also cast to `[string]`, because `ConvertTo-Json` on a decorated object
# serialises its PSPath, PSProvider and the whole member table of its type.

param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Owner = 'EvGeNkA-PLUSsss',
    [string]$Repository = 'darkflow',
    [string]$DistDirectory = 'dist'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$notesPath = Join-Path $root "docs\release-notes\$Version.md"
if (-not (Test-Path $notesPath)) {
    throw "no release notes at $notesPath - write them before publishing, because a release without them is a download link with no description"
}

$cred = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
$token = ($cred -split "`n" | Where-Object { $_ -match '^password=' }) -replace '^password=', ''
if (-not $token) { throw 'no GitHub credential available' }

$headers = @{
    Authorization = "Bearer $token"
    'User-Agent'  = 'dsh'
    Accept        = 'application/vnd.github+json'
}

$body = [string][IO.File]::ReadAllText($notesPath, [Text.Encoding]::UTF8)

$payload = @{
    tag_name   = $Version
    name       = "DarkFlow $($Version.TrimStart('v'))"
    body       = $body
    draft      = $false
    prerelease = $false
} | ConvertTo-Json -Depth 3

$release = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/$Owner/$Repository/releases" `
    -Method Post -Headers $headers -Body $payload `
    -ContentType 'application/json; charset=utf-8' -TimeoutSec 60

Write-Host "release: $($release.tag_name)  id=$($release.id)"
Write-Host "  $($release.html_url)"

# The upload host is not the API host, and an asset needs an explicit content type or GitHub
# stores it as application/octet-stream.
$uploadBase = "https://uploads.github.com/repos/$Owner/$Repository/releases/$($release.id)/assets"

$assets = @(
    @{ Pattern = '*-windows-x64.zip'; Type = 'application/zip' },
    @{ Pattern = '*-android-arm64.apk'; Type = 'application/vnd.android.package-archive' }
)

foreach ($asset in $assets) {
    $matches = @(Get-ChildItem -Path (Join-Path $root $DistDirectory) -Filter $asset.Pattern -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 0) {
        Write-Host "  no artifact matching $($asset.Pattern), skipped"
        continue
    }
    if ($matches.Count -gt 1) {
        throw "more than one artifact matches $($asset.Pattern); remove the stale ones first"
    }

    $file = $matches[0]
    $sizeMb = [math]::Round($file.Length / 1MB, 1)
    Write-Host "uploading $($file.Name) ($sizeMb MB)..."
    $url = $uploadBase + '?name=' + [uri]::EscapeDataString($file.Name)
    try {
        $uploaded = Invoke-RestMethod -Uri $url -Method Post -Headers $headers `
            -InFile $file.FullName -ContentType $asset.Type -TimeoutSec 1800
        Write-Host "  uploaded: $($uploaded.name)  $([math]::Round($uploaded.size / 1MB, 1)) MB"
        Write-Host "  $($uploaded.browser_download_url)"
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)"
        throw
    }
}

Write-Host 'DONE'
