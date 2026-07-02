<#
UU Remote Clipboard - Watch Only Mode (no reset)
Monitors clipboard status every 10 seconds
Press Ctrl+C to stop
#>

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ClipWatcher {
    [DllImport("user32.dll")] public static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder t, int m);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);

    public static string Detect() {
        IntPtr hOpen = GetOpenClipboardWindow();
        if (hOpen != IntPtr.Zero && IsWindow(hOpen)) {
            uint pid; GetWindowThreadProcessId(hOpen, out pid);
            var sb = new System.Text.StringBuilder(256);
            GetWindowText(hOpen, sb, sb.Capacity);
            return "BLOCKED:PID=" + pid + ":" + sb.ToString();
        }
        return "FREE";
    }
}
"@

$host.UI.RawUI.WindowTitle = "UU Clipboard Status Watch"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Clipboard Status Monitor (read-only)" -ForegroundColor Cyan
Write-Host "  Press Ctrl+C to stop" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

while ($true) {
    $t = Get-Date -Format "HH:mm:ss"
    $info = [ClipWatcher]::Detect()

    if ($info -eq "FREE") {
        Write-Host ("[$t] Free - clipboard available") -ForegroundColor Green
    } else {
        if ($info -match 'PID=(\d+):(.+)') {
            $procId = $matches[1]
            $title = $matches[2]
            try {
                $p = Get-Process -Id $procId -ErrorAction Stop
                Write-Host ("[$t] Held by " + $p.ProcessName + " (PID=" + $procId + ") '" + $title + "'") -ForegroundColor Yellow
            } catch {
                Write-Host ("[$t] Held by PID=" + $procId + " (process gone)") -ForegroundColor Yellow
            }
        } else {
            Write-Host ("[$t] Held - " + $info) -ForegroundColor Yellow
        }
    }

    Start-Sleep -Seconds 10
}
