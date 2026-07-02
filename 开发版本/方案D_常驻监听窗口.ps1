<#
UU Clipboard Reset - Scheme D Lite (Polling-based v2)
Multi-layer clipboard recovery, lightweight polling.
Close the window or press Ctrl+C to stop.
#>

$ErrorActionPreference = "SilentlyContinue"
try { [System.Console]::Title = "UU Clipboard Monitor - DO NOT CLOSE" } catch {}

# Auto-close any existing .NET error dialogs before starting
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class DialogCloser {
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder t, int m);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    const uint WM_CLOSE = 0x0010;
    public static string CloseAll() {
        StringBuilder sb = new StringBuilder(256); string r = "";
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            GetWindowText(h, sb, 256); string t = sb.ToString().Trim();
            if (t.Length == 0) return true;
            if (t.IndexOf(".NET", StringComparison.OrdinalIgnoreCase) >= 0 ||
                t.IndexOf("Error", StringComparison.OrdinalIgnoreCase) >= 0 ||
                t.IndexOf("Exception", StringComparison.OrdinalIgnoreCase) >= 0) {
                uint pid; GetWindowThreadProcessId(h, out pid);
                SendMessage(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                r += "Closed: [" + t + "] PID=" + pid + " ";
            }
            return true;
        }, IntPtr.Zero);
        return r.Length > 0 ? r : null;
    }
}
"@
$closedDialogs = [DialogCloser]::CloseAll()
if ($closedDialogs) { Write-Host ("Cleaned up: " + $closedDialogs) -ForegroundColor DarkGray }

#region Clipboard detection
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ClipCheck {
    [DllImport("user32.dll")] public static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder t, int m);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    public static string Detect() {
        IntPtr hOpen = GetOpenClipboardWindow();
        if (hOpen != IntPtr.Zero && IsWindow(hOpen)) {
            uint pid; GetWindowThreadProcessId(hOpen, out pid);
            int L = GetWindowTextLength(hOpen);
            var sb = new System.Text.StringBuilder(L + 1);
            GetWindowText(hOpen, sb, sb.Capacity);
            return "BLOCKED: HWND=" + hOpen + " PID=" + pid + " Title='" + sb.ToString() + "'";
        }
        return "FREE";
    }
    public static bool IsFree() {
        IntPtr h = GetOpenClipboardWindow();
        return h == IntPtr.Zero || !IsWindow(h);
    }
}
"@
#endregion

#region Win32 force reset (OpenClipboard retry)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Clip {
    [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32.dll")] public static extern bool CloseClipboard();
    [DllImport("user32.dll")] public static extern bool EmptyClipboard();
    public static bool Reset() {
        for (int i = 0; i < 50; i++) {
            if (OpenClipboard(IntPtr.Zero)) {
                EmptyClipboard();
                CloseClipboard();
                return true;
            }
            System.Threading.Thread.Sleep(100);
        }
        return false;
    }
}
"@
#endregion

function Write-Log {
    param([string]$msg, [string]$color = "Gray")
    $t = Get-Date -Format "HH:mm:ss"
    Write-Host ("[$t] $msg") -ForegroundColor $color
}

function Invoke-Recovery {
    param([string]$trigger = "unknown")
    $ok = $false
    $layers = @()

    Write-Log ("Recovery triggered ($trigger)") "Cyan"

    # L0: Fast OLE reset
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Clipboard]::Clear()
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.Clipboard]::SetText(' ')
        $ok = $true
        Write-Log "L0: Fast OLE reset OK" "Green"
    } catch {
        Write-Log "L0: Fast OLE reset FAIL" "DarkYellow"
        $layers += "L0"
    }

    # L1: STA message pump OLE
    if (-not $ok) {
        try {
            $f = New-Object System.Windows.Forms.Form
            $f.WindowState = "Minimized"
            $f.ShowInTaskbar = $false
            $f.Add_Shown({
                [System.Windows.Forms.Clipboard]::Clear()
                Start-Sleep -Milliseconds 300
                [System.Windows.Forms.Clipboard]::SetText(' ')
                $f.Close()
            })
            [System.Windows.Forms.Application]::DoEvents()
            [System.Windows.Forms.Application]::Run($f)
            $ok = $true
            Write-Log "L1: STA message pump OLE OK" "Green"
        } catch {
            Write-Log "L1: STA message pump OLE FAIL" "DarkYellow"
            $layers += "L1"
        }
    }

    # L2: Win32 OpenClipboard retry (50 times)
    if (-not $ok) {
        $r = [Win32Clip]::Reset()
        if ($r) {
            Write-Log "L2: Win32 retry OK" "Green"
            $ok = $true
        } else {
            Write-Log "L2: Win32 retry FAIL" "DarkYellow"
            $layers += "L2"
        }
    }

    # L3: WM_CLOSE to blocker window
    if (-not $ok) {
        $d = [DialogCloser]::CloseAll()
        if ($d) {
            Write-Log ("L3: Closed dialogs: " + $d) "Green"
            Start-Sleep -Seconds 1
            try {
                [System.Windows.Forms.Clipboard]::Clear()
                [System.Windows.Forms.Clipboard]::SetText(' ')
                $ok = $true
            } catch {}
        } else {
            Write-Log "L3: No dialogs found" "DarkYellow"
            $layers += "L3"
        }
    }

    # L4: Kill blocker process
    if (-not $ok) {
        $info = [ClipCheck]::Detect()
        if ($info -match 'PID=(\d+)') {
            $pid = $matches[1]
            try {
                $p = Get-Process -Id $pid -ErrorAction Stop
                Write-Log ("L4: Killing " + $p.ProcessName + " PID=" + $pid) "Yellow"
                $p.Kill()
                $p.WaitForExit(3000)
                Start-Sleep -Seconds 1
                [System.Windows.Forms.Clipboard]::Clear()
                [System.Windows.Forms.Clipboard]::SetText(' ')
                $ok = $true
                Write-Log "L4: Kill OK" "Green"
            } catch {
                Write-Log ("L4: Kill FAIL - " + $_.Exception.Message) "DarkYellow"
                $layers += "L4"
            }
        } else {
            Write-Log "L4: No holder process detected" "DarkYellow"
            $layers += "L4"
        }
    }

    # L5: Restart explorer.exe
    if (-not $ok) {
        try {
            Write-Log "L5: Restarting explorer.exe..." "Yellow"
            Get-Process explorer | Stop-Process -Force
            Start-Sleep -Seconds 3
            $ok = $true
            Write-Log "L5: explorer restarted" "Green"
        } catch {
            Write-Log ("L5: explorer restart FAIL - " + $_.Exception.Message) "DarkYellow"
            $layers += "L5"
        }
    }

    if ($ok) {
        Write-Log ("Recovery OK (trigger=$trigger, layers tried: " + ($layers -join ",") + ")") "Green"
    } else {
        Write-Log ("Recovery FAILED after all layers (trigger=$trigger)") "Red"
    }
}

#region Main - Lightweight polling loop
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  ClipWatcher - Scheme D Lite" -ForegroundColor Cyan
Write-Host "  Multi-layer clipboard recovery (polling)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Recovery layers (L0-L5):" -ForegroundColor Cyan
Write-Host "    L0: Fast OLE reset"
Write-Host "    L1: OLE with STA message pump"
Write-Host "    L2: Win32 OpenClipboard retry"
Write-Host "    L3: WM_CLOSE to blocker window"
Write-Host "    L4: Kill blocker process"
Write-Host "    L5: Restart explorer.exe"
Write-Host ""
Write-Host "  Close this window or press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

Write-Log "Listener started (polling every 5s)" "Cyan"
Write-Log ""

$prevFree = $null
while ($true) {
    $isFree = [ClipCheck]::IsFree()
    $t = Get-Date -Format "HH:mm:ss"

    if (-not $isFree) {
        # Clipboard locked - trigger recovery
        Write-Host ("[$t] Clipboard LOCKED - starting recovery...") -ForegroundColor Yellow
        Invoke-Recovery -trigger "poll"
        $prevFree = $null  # force fresh display next time
        Write-Host ""
    } else {
        # Free: only show latest status (overwrite same line)
        $msg = "[$t] Clipboard FREE - monitoring..."
        if ($prevFree -eq $true) {
            try {
                [Console]::CursorTop = [Console]::CursorTop - 1
                Write-Host (" " * 80)
                [Console]::CursorTop = [Console]::CursorTop - 1
            } catch {}
            Write-Host $msg -ForegroundColor Green
        } else {
            Write-Host $msg -ForegroundColor Green
        }
        $prevFree = $true
    }

    Start-Sleep -Seconds 5
}
#endregion
