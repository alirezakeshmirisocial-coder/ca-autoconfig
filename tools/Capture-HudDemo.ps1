[CmdletBinding()]
param(
    [string]$OutputPath = '',
    [string]$FrameDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $repositoryRoot 'docs\assets\hud-demo.gif' }
if ([string]::IsNullOrWhiteSpace($FrameDirectory)) { $FrameDirectory = Join-Path $repositoryRoot 'artifacts\hud-demo-frames' }
Add-Type -AssemblyName System.Drawing

if (-not ('CAHudDemoCapture' -as [type])) {
    $drawingAssembly = [Drawing.Bitmap].Assembly.Location
    $drawingReferences = @($drawingAssembly)
    foreach ($supportAssemblyName in @('System.Drawing.Primitives.dll', 'System.Private.Windows.Core.dll', 'System.Private.Windows.GdiPlus.dll')) {
        $supportAssembly = Join-Path $PSHOME $supportAssemblyName
        if (Test-Path -LiteralPath $supportAssembly) { $drawingReferences += $supportAssembly }
    }
    Add-Type -ReferencedAssemblies $drawingReferences -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public static class CAHudDemoCapture
{
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    public static void EnablePerMonitorDpi() { SetThreadDpiAwarenessContext(new IntPtr(-4)); }

    public static IntPtr FindWindow(uint processId, string title, bool requireTitle)
    {
        IntPtr match = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr ignored) {
            uint candidate; GetWindowThreadProcessId(hwnd, out candidate);
            if (candidate != processId || !IsWindowVisible(hwnd)) return true;
            StringBuilder text = new StringBuilder(256); GetWindowText(hwnd, text, text.Capacity);
            Rect rect; GetWindowRect(hwnd, out rect);
            bool titleMatches = String.Equals(text.ToString(), title ?? String.Empty, StringComparison.OrdinalIgnoreCase);
            if ((requireTitle && titleMatches) || (!requireTitle && String.IsNullOrEmpty(text.ToString()) && rect.Right - rect.Left > 250 && rect.Bottom - rect.Top > 250))
            { match = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return match;
    }

    public static bool IsLocked(IntPtr hwnd)
    {
        Rect rect; if (!GetWindowRect(hwnd, out rect)) return true;
        int x = rect.Left + 60, y = rect.Top + 80;
        long packed = ((long)(ushort)y << 16) | (ushort)x;
        return SendMessage(hwnd, 0x0084, IntPtr.Zero, new IntPtr(packed)).ToInt64() == -1;
    }

    public static void ToggleLock(IntPtr hwnd)
    {
        Rect rect; if (!GetWindowRect(hwnd, out rect)) throw new InvalidOperationException("HUD bounds unavailable.");
        double scale = Math.Max(0.5, (rect.Right - rect.Left) / 320.0);
        int x = (int)Math.Round(288.0 * scale), y = (int)Math.Round(21.0 * scale);
        IntPtr packed = new IntPtr((y << 16) | (x & 0xFFFF));
        SendMessage(hwnd, 0x0201, new IntPtr(1), packed);
        SendMessage(hwnd, 0x0202, IntPtr.Zero, packed);
    }

    public static void CloseWindow(IntPtr hwnd) { if (hwnd != IntPtr.Zero) PostMessage(hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero); }

    public static Bitmap Capture(IntPtr hwnd)
    {
        Rect rect; if (!GetWindowRect(hwnd, out rect)) throw new InvalidOperationException("Window bounds unavailable.");
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) throw new InvalidOperationException("Window has invalid bounds.");
        Bitmap bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            IntPtr hdc = graphics.GetHdc();
            try { if (!PrintWindow(hwnd, hdc, 2)) throw new InvalidOperationException("PrintWindow failed."); }
            finally { graphics.ReleaseHdc(hdc); }
        }
        return bitmap;
    }

    public static Bitmap Compose(Bitmap capture, string eyebrow, string title, string detail)
    {
        Bitmap canvas = new Bitmap(1000, 780, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(canvas))
        using (SolidBrush background = new SolidBrush(Color.FromArgb(10, 15, 20)))
        using (SolidBrush text = new SolidBrush(Color.FromArgb(235, 240, 246)))
        using (SolidBrush muted = new SolidBrush(Color.FromArgb(150, 166, 184)))
        using (SolidBrush accent = new SolidBrush(Color.FromArgb(92, 220, 167)))
        using (Font eyebrowFont = new Font("Segoe UI Semibold", 20, FontStyle.Bold, GraphicsUnit.Pixel))
        using (Font titleFont = new Font("Segoe UI Semibold", 48, FontStyle.Bold, GraphicsUnit.Pixel))
        using (Font detailFont = new Font("Segoe UI", 23, FontStyle.Regular, GraphicsUnit.Pixel))
        {
            g.FillRectangle(background, 0, 0, canvas.Width, canvas.Height);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            g.DrawString(eyebrow.ToUpperInvariant(), eyebrowFont, accent, new PointF(54, 38));
            g.DrawString(title, titleFont, text, new PointF(50, 67));
            g.DrawString(detail, detailFont, muted, new RectangleF(54, 126, 890, 50));

            float maximumWidth = 900, maximumHeight = 565;
            float scale = Math.Min(maximumWidth / capture.Width, maximumHeight / capture.Height);
            scale = Math.Min(scale, 1.35f);
            int width = (int)Math.Round(capture.Width * scale), height = (int)Math.Round(capture.Height * scale);
            int left = (canvas.Width - width) / 2, top = 184 + Math.Max(0, (565 - height) / 2);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(capture, new Rectangle(left, top, width, height));
        }
        return canvas;
    }

    public static void SaveAnimatedGif(Bitmap[] frames, string path, int delayCentiseconds)
    {
        if (frames == null || frames.Length == 0) throw new ArgumentException("At least one frame is required.");
        ImageCodecInfo codec = null;
        foreach (ImageCodecInfo candidate in ImageCodecInfo.GetImageEncoders())
            if (candidate.FormatID == ImageFormat.Gif.Guid) { codec = candidate; break; }
        if (codec == null) throw new InvalidOperationException("GIF encoder unavailable.");

        PropertyItem delays = (PropertyItem)Activator.CreateInstance(typeof(PropertyItem), true);
        delays.Id = 0x5100; delays.Type = 4; delays.Len = frames.Length * 4; delays.Value = new byte[delays.Len];
        for (int i = 0; i < frames.Length; i++) Array.Copy(BitConverter.GetBytes(delayCentiseconds), 0, delays.Value, i * 4, 4);
        PropertyItem loop = (PropertyItem)Activator.CreateInstance(typeof(PropertyItem), true);
        loop.Id = 0x5101; loop.Type = 3; loop.Len = 2; loop.Value = BitConverter.GetBytes((ushort)0);
        frames[0].SetPropertyItem(delays); frames[0].SetPropertyItem(loop);

        EncoderParameters parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.SaveFlag, (long)EncoderValue.MultiFrame);
        frames[0].Save(path, codec, parameters);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.SaveFlag, (long)EncoderValue.FrameDimensionTime);
        for (int i = 1; i < frames.Length; i++) frames[0].SaveAdd(frames[i], parameters);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.SaveFlag, (long)EncoderValue.Flush);
        frames[0].SaveAdd(parameters);
        parameters.Dispose();
    }
}
'@
}

[CAHudDemoCapture]::EnablePerMonitorDpi()

$process = Get-CimInstance Win32_Process -Filter "Name='CAAutoConfig.exe'" | Select-Object -First 1
if ($null -eq $process) { throw 'The compiled CA AutoConfig HUD is not running.' }
$processId = [uint32]$process.ProcessId
$hud = [CAHudDemoCapture]::FindWindow($processId, '', $false)
if ($hud -eq [IntPtr]::Zero) { throw 'The visible HUD window was not found.' }

$existingSettings = [CAHudDemoCapture]::FindWindow($processId, 'CA HUD settings', $true)
if ($existingSettings -ne [IntPtr]::Zero) {
    [CAHudDemoCapture]::CloseWindow($existingSettings)
    Start-Sleep -Milliseconds 500
}

$frames = New-Object Collections.Generic.List[Drawing.Bitmap]
$captures = New-Object Collections.Generic.List[Drawing.Bitmap]
try {
    if (-not [CAHudDemoCapture]::IsLocked($hud)) {
        [CAHudDemoCapture]::ToggleLock($hud)
        Start-Sleep -Milliseconds 400
    }
    $locked = [CAHudDemoCapture]::Capture($hud); $captures.Add($locked)
    $frames.Add([CAHudDemoCapture]::Compose($locked, 'Always visible, never in the way', 'Locked HUD', 'The tiny lock pill stays clickable; every other pixel passes clicks through to your work.'))

    [CAHudDemoCapture]::ToggleLock($hud)
    Start-Sleep -Milliseconds 500
    $unlocked = [CAHudDemoCapture]::Capture($hud); $captures.Add($unlocked)
    $frames.Add([CAHudDemoCapture]::Compose($unlocked, 'One deliberate gesture', 'Edit mode', 'Drag the HUD or right-click for settings, then lock it again with your own shortcut.'))

    $request = [Threading.EventWaitHandle]::OpenExisting('Local\CA-SystemOverlay-OpenSettings')
    $request.Set() | Out-Null; $request.Dispose()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 150
        $settings = [CAHudDemoCapture]::FindWindow($processId, 'CA HUD settings', $true)
    } while ($settings -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($settings -eq [IntPtr]::Zero) { throw 'The HUD settings window did not open.' }
    $settingsCapture = [CAHudDemoCapture]::Capture($settings); $captures.Add($settingsCapture)
    $frames.Add([CAHudDemoCapture]::Compose($settingsCapture, 'Your workstation, your layout', 'Monitor map + shortcut', 'Choose a display, opacity, and hotkey; inspect limits and copy a sanitized report.'))

    $outputDirectory = Split-Path -Parent $OutputPath
    New-Item -ItemType Directory -Force -Path $outputDirectory, $FrameDirectory | Out-Null
    for ($index = 0; $index -lt $frames.Count; $index++) {
        $frames[$index].Save((Join-Path $FrameDirectory ("frame-{0}.png" -f ($index + 1))), [Drawing.Imaging.ImageFormat]::Png)
    }
    [CAHudDemoCapture]::SaveAnimatedGif($frames.ToArray(), $OutputPath, 240)
}
finally {
    $settings = [CAHudDemoCapture]::FindWindow($processId, 'CA HUD settings', $true)
    if ($settings -ne [IntPtr]::Zero) { [CAHudDemoCapture]::CloseWindow($settings) }
    if (-not [CAHudDemoCapture]::IsLocked($hud)) { [CAHudDemoCapture]::ToggleLock($hud) }
    foreach ($bitmap in $frames) { $bitmap.Dispose() }
    foreach ($bitmap in $captures) { $bitmap.Dispose() }
}

[pscustomobject]@{
    Status = 'Captured'
    Output = [IO.Path]::GetFullPath($OutputPath)
    Bytes = (Get-Item -LiteralPath $OutputPath).Length
    Frames = 3
    DesktopPixelsCaptured = $false
    HudRestoredLocked = [CAHudDemoCapture]::IsLocked($hud)
}
