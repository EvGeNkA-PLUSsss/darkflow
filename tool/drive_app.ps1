# Drives DarkFlow through its onboarding flow and screenshots each step.
#
# A successful build says nothing about whether the vault can actually be
# created, whether Argon2id runs in reasonable time, or whether the bundled Tor
# daemon starts. This script walks the real UI — typing into the real fields —
# and captures what happens, so those claims are observed rather than assumed.
#
# Usage:  pwsh -File tool/drive_app.ps1 [-TailSeconds 90]

param(
    [string]$Name = 'Mike',
    [string]$About = 'Testing DarkFlow on Windows',
    [string]$Password = 'darkflow-test-passphrase-2024',
    [string]$Pin = '246813',
    [int]$TailSeconds = 100,
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'build\windows\x64\runner\Release\darkflow.exe'
$shots = Join-Path $root 'render'
New-Item -ItemType Directory -Force -Path $shots | Out-Null

if (-not (Test-Path $exe)) { throw "Build first: $exe does not exist." }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Drv {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hWnd);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    public static readonly IntPtr TOPMOST = new IntPtr(-1);
    public static readonly IntPtr NOTOPMOST = new IntPtr(-2);
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
}
'@

$script:proc = $null
$script:handle = [IntPtr]::Zero
$script:rect = $null

function Raise-App {
    if ($script:handle -eq [IntPtr]::Zero) { return }
    [void][Drv]::SetWindowPos($script:handle, [Drv]::TOPMOST, 0, 0, 0, 0,
        [Drv]::SWP_NOMOVE -bor [Drv]::SWP_NOSIZE -bor [Drv]::SWP_SHOWWINDOW)
    [void][Drv]::BringWindowToTop($script:handle)
    [void][Drv]::SetForegroundWindow($script:handle)
    Start-Sleep -Milliseconds 700
}

function Capture([string]$label) {
    if ($script:rect -eq $null) { return }
    Raise-App
    $bitmap = New-Object System.Drawing.Bitmap $script:rect.Width, $script:rect.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($script:rect.X, $script:rect.Y, 0, 0, $bitmap.Size)
    $path = Join-Path $shots "app_$label.png"
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
    Write-Host "  captured $label"
}

function Send([string]$keys, [int]$pauseMs = 500) {
    Raise-App
    [System.Windows.Forms.SendKeys]::SendWait($keys)
    Start-Sleep -Milliseconds $pauseMs
}

# Types a string in small chunks.
#
# SendKeys fires keys as fast as the message queue accepts them, and a Flutter
# text field that rebuilds on every character drops some of them. Chunking with
# a short pause is what makes a long password arrive intact.
function TypeText([string]$text, [int]$chunk = 3, [int]$pauseMs = 120) {
    Raise-App
    for ($i = 0; $i -lt $text.Length; $i += $chunk) {
        $piece = $text.Substring($i, [Math]::Min($chunk, $text.Length - $i))
        [System.Windows.Forms.SendKeys]::SendWait($piece)
        Start-Sleep -Milliseconds $pauseMs
    }
}

$script:proc = Start-Process -FilePath $exe -PassThru
Write-Host "started pid $($script:proc.Id)"

# First paint, plus the one-off cost of unpacking the Tor runtime.
Start-Sleep -Seconds 18
$script:proc.Refresh()
$script:handle = $script:proc.MainWindowHandle
for ($i = 0; $i -lt 30 -and $script:handle -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 500
    $script:proc.Refresh()
    $script:handle = $script:proc.MainWindowHandle
}
if ($script:handle -eq [IntPtr]::Zero) { throw 'the app never opened a window' }

$r = New-Object Drv+RECT
[void][Drv]::GetWindowRect($script:handle, [ref]$r)
$script:rect = New-Object System.Drawing.Rectangle $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top)
Write-Host "window $($script:rect.Width)x$($script:rect.Height)"

# ---------------------------------------------------------------- step 1
Capture '1_signup'
Raise-App
# Click the Name field, then type. Clicking is more reliable than relying on
# the initial focus, which the window manager may not have delivered.
$namePoint = New-Object System.Drawing.Point ($script:rect.X + 640), ($script:rect.Y + 326)
[System.Windows.Forms.Cursor]::Position = $namePoint
Start-Sleep -Milliseconds 250
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);' -Name Mouse -Namespace Drv | Out-Null
[Drv.Mouse]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
[Drv.Mouse]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 400
TypeText $Name
Send '{TAB}'
TypeText $About
# Tab to the button and activate it with the keyboard rather than relying on
# the field's onSubmitted handler: a focused Flutter button responds to Enter,
# which exercises the same code path the mouse would.
Send '{TAB}'
Send '{ENTER}'
Start-Sleep -Seconds 3
Capture '2_password'

# ---------------------------------------------------------------- step 2
$pwPoint = New-Object System.Drawing.Point ($script:rect.X + 640), ($script:rect.Y + 360)
[System.Windows.Forms.Cursor]::Position = $pwPoint
Start-Sleep -Milliseconds 250
[Drv.Mouse]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
[Drv.Mouse]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 400
TypeText $Password 1 350
Send '{TAB}' 700
TypeText $Password 1 350
Send '{TAB}' 700
Send '{ENTER}'
Start-Sleep -Seconds 3
Capture '3_pin'

# ---------------------------------------------------------------- step 3
# The PIN field takes focus automatically; typing six digits is enough. One key
# per 400 ms is slow enough that the hidden text field never coalesces two.
TypeText $Pin 1 400
Start-Sleep -Milliseconds 600
Capture '3b_pin_typed'
Send '{TAB}' 700
Send '{ENTER}'
Write-Host '  account submitted; waiting for key derivation and Tor'
Start-Sleep -Seconds 12
Capture '4_after_pin'

# Watch the Tor connection screen for a while: either it bootstraps or it
# reports why it could not, and both are worth seeing.
$elapsed = 12
while ($elapsed -lt $TailSeconds) {
    Start-Sleep -Seconds 10
    $elapsed += 10
    Capture "tor_$elapsed"
    if ($script:proc.HasExited) {
        Write-Host "the app exited with code $($script:proc.ExitCode)"
        break
    }
}

if (-not $KeepRunning) {
    Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue
    Write-Host 'stopped the app'
} else {
    Write-Host "leaving pid $($script:proc.Id) running"
}
