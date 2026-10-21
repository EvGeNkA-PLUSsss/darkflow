# Launches the built DarkFlow and captures a screenshot of its window.
#
# Used to verify the app really starts and renders, rather than trusting that a
# successful build implies a working UI.
#
# Usage:  pwsh -File tool/capture_app.ps1 [-WaitSeconds 20] [-Out render/app.png]

param(
    [int]$WaitSeconds = 20,
    [string]$Out = 'render\app.png',
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'build\windows\x64\runner\Release\darkflow.exe'
$outPath = Join-Path $root $Out

if (-not (Test-Path $exe)) { throw "Build first: $exe does not exist." }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32Window {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
}
'@

$process = Start-Process -FilePath $exe -PassThru
Write-Host "started pid $($process.Id)"

# Give the app time to unpack Tor, derive keys and paint its first frame.
Start-Sleep -Seconds $WaitSeconds

if ($process.HasExited) {
    throw "the app exited after $WaitSeconds s with code $($process.ExitCode)"
}

# Flutter keeps several message-only windows alive, so the main window is found
# by asking for the process's window with a title rather than the first handle.
$process.Refresh()
$handle = $process.MainWindowHandle
for ($i = 0; $i -lt 20 -and $handle -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 500
    $process.Refresh()
    $handle = $process.MainWindowHandle
}

if ($handle -eq [IntPtr]::Zero) {
    Write-Host 'no main window handle; capturing the whole screen instead'
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $rect = New-Object System.Drawing.Rectangle $bounds.X, $bounds.Y, $bounds.Width, $bounds.Height
    $capture = 'screen'
} else {
    # A background process cannot normally steal the foreground, so the window
    # is raised with the topmost flag instead, which the shell does honour.
    [void][Win32Window]::ShowWindow($handle, 5)
    [void][Win32Window]::SetWindowPos($handle, [Win32Window]::HWND_TOPMOST, 0, 0, 0, 0,
        [Win32Window]::SWP_NOMOVE -bor [Win32Window]::SWP_NOSIZE -bor [Win32Window]::SWP_SHOWWINDOW)
    [void][Win32Window]::BringWindowToTop($handle)
    [void][Win32Window]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 1500

    $r = New-Object Win32Window+RECT
    [void][Win32Window]::GetWindowRect($handle, [ref]$r)
    $rect = New-Object System.Drawing.Rectangle $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top)
    Write-Host "window rect $($rect.Width)x$($rect.Height) at $($rect.X),$($rect.Y)"
    $capture = 'window'
}

$bitmap = New-Object System.Drawing.Bitmap $rect.Width, $rect.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($rect.X, $rect.Y, 0, 0, $bitmap.Size)
$bitmap.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
Write-Host "captured $outPath ($capture)"

if ($handle -ne [IntPtr]::Zero) {
    [void][Win32Window]::SetWindowPos($handle, [Win32Window]::HWND_NOTOPMOST, 0, 0, 0, 0,
        [Win32Window]::SWP_NOMOVE -bor [Win32Window]::SWP_NOSIZE)
}

if (-not $KeepRunning) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    Write-Host 'stopped the app'
} else {
    Write-Host "leaving pid $($process.Id) running"
}
