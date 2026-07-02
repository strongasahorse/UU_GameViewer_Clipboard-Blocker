<#
UU Clipboard Unlocker - Universal Fix Tool v1.0
一键诊断并修复远程软件（UU Remote / GameViewer 等）锁定剪贴板的问题。
用法：直接运行，按菜单选择操作。
#>

Add-Type -AssemblyName System.Windows.Forms

# 设置窗口标题
try { $host.UI.RawUI.WindowTitle = "UU Clipboard Unlocker" } catch {}

#region C# 工具类
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ClipDetect {
    [DllImport("user32.dll")] public static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder t, int m);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);

    public static string GetOwnerInfo() {
        IntPtr h = GetOpenClipboardWindow();
        if (h == IntPtr.Zero || !IsWindow(h)) return null;
        uint pid; GetWindowThreadProcessId(h, out pid);
        int len = GetWindowTextLength(h);
        var sb = new System.Text.StringBuilder(len + 1);
        GetWindowText(h, sb, sb.Capacity);
        return "PID=" + pid + " HWND=" + h + " Title='" + sb.ToString() + "'";
    }

    public static bool IsFree() {
        IntPtr h = GetOpenClipboardWindow();
        return h == IntPtr.Zero || !IsWindow(h);
    }
}

public class Win32Clip {
    [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32.dll")] public static extern bool CloseClipboard();
    [DllImport("user32.dll")] public static extern bool EmptyClipboard();

    public static bool ForceReset() {
        for (int i = 0; i < 60; i++) {
            if (OpenClipboard(IntPtr.Zero)) {
                EmptyClipboard();
                CloseClipboard();
                return true;
            }
            System.Threading.Thread.Sleep(200);
        }
        return false;
    }
}
"@
#endregion

function Write-Step {
    param([string]$msg, [string]$color = "White")
    $t = Get-Date -Format "HH:mm:ss"
    Write-Host ("[$t] $msg") -ForegroundColor $color
}

function Show-Banner {
    Clear-Host
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "   UU Clipboard Unlocker v1.0" -ForegroundColor Cyan
    Write-Host "   远程剪贴板锁定一键修复" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Step-Detect {
    Write-Step "Checking clipboard status..." "Cyan"
    $info = [ClipDetect]::GetOwnerInfo()
    if ($info -eq $null) {
        Write-Step "Clipboard is FREE (not locked)" "Green"
        return $true
    }
    Write-Step ("LOCKED by: " + $info) "Red"
    if ($info -match 'PID=(\d+)') {
        $pid = $matches[1]
        try {
            $p = Get-Process -Id $pid -ErrorAction Stop
            Write-Step ("  Process: " + $p.ProcessName + " (PID=" + $pid + ")") "Yellow"
        } catch {
            Write-Step ("  Process PID=" + $pid + " (not found / already dead)") "Yellow"
        }
    }
    return $false
}

function Step-OleReset {
    Write-Step "Trying OLE reset (System.Windows.Forms.Clipboard)..." "Cyan"
    $ok = $false
    try {
        [System.Windows.Forms.Clipboard]::Clear()
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.Clipboard]::SetText(' ')
        Write-Step "OLE reset OK" "Green"
        return $true
    } catch {
        Write-Step "OLE reset FAILED" "DarkYellow"
    }

    # Try with STA message pump
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.WindowState = "Minimized"
        $form.ShowInTaskbar = $false
        $form.Add_Shown({
            [System.Windows.Forms.Clipboard]::Clear()
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.Clipboard]::SetText(' ')
            $form.Close()
        })
        [System.Windows.Forms.Application]::DoEvents()
        [System.Windows.Forms.Application]::Run($form)
        Write-Step "OLE reset (STA pump) OK" "Green"
        return $true
    } catch {
        Write-Step "OLE reset (STA pump) FAILED" "DarkYellow"
    }
    return $false
}

function Step-Win32Reset {
    Write-Step "Trying Win32 force reset (60 retries)..." "Cyan"
    if ([Win32Clip]::ForceReset()) {
        Write-Step "Win32 force reset OK" "Green"
        return $true
    }
    Write-Step "Win32 force reset FAILED (still locked)" "DarkYellow"
    return $false
}

function Step-KillHolder {
    Write-Step "Trying to kill the holder process..." "Yellow"
    $info = [ClipDetect]::GetOwnerInfo()
    if ($info -match 'PID=(\d+)') {
        $pid = $matches[1]
        try {
            $p = Get-Process -Id $pid -ErrorAction Stop
            Write-Step ("Killing: " + $p.ProcessName + " (PID=" + $pid + ")") "Red"
            $p.Kill()
            $p.WaitForExit(5000)
            Start-Sleep -Seconds 1
            Write-Step "Process killed" "Green"
            return $true
        } catch {
            Write-Step ("Cannot kill: " + $_.Exception.Message) "Red"
        }
    }
    return $false
}

function Step-ResetExplorer {
    Write-Step "Restarting explorer.exe..." "Yellow"
    try {
        Get-Process explorer -ErrorAction Stop | Stop-Process -Force
        Start-Sleep -Seconds 3
        Write-Step "Explorer restarted" "Green"
        return $true
    } catch {
        Write-Step ("Explorer restart FAILED: " + $_.Exception.Message) "Red"
    }
    return $false
}

function Do-FullFix {
    Write-Step "========== FULL FIX ==========" "Cyan"
    
    if ([ClipDetect]::IsFree()) {
        Write-Step "Clipboard already free, just doing OLE reset..." "Green"
        Step-OleReset | Out-Null
        return
    }

    # L1: Try OLE reset first (fastest)
    if (Step-OleReset) { return }

    # L2: OLE reset with STA pump
    # (already attempted inside Step-OleReset)

    # L3: Win32 force reset with retry
    if (Step-Win32Reset) { 
        Step-OleReset | Out-Null
        return 
    }

    # L4: Kill holder process
    if (Step-KillHolder) {
        Start-Sleep -Milliseconds 500
        if (Step-OleReset) { return }
        if (Step-Win32Reset) { return }
    }

    # L5: Restart explorer (nuclear option)
    Write-Step "All soft methods failed, restarting explorer.exe..." "Yellow"
    Step-ResetExplorer
    Start-Sleep -Seconds 2
    Step-OleReset | Out-Null
}

function Show-Menu {
    do {
        Show-Banner
        Write-Host " ClipCheck - clipboard status" -ForegroundColor Gray
        $isFree = [ClipDetect]::IsFree()
        if ($isFree) {
            Write-Host "  Current: [FREE]" -ForegroundColor Green
        } else {
            $info = [ClipDetect]::GetOwnerInfo()
            Write-Host ("  Current: [LOCKED] " + $info) -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "  1. Check clipboard status"
        Write-Host "  2. OLE reset (soft)"
        Write-Host "  3. Win32 force reset (retry 60x)"
        Write-Host "  4. Auto fix (L1->L2->L3->L4->L5)"
        Write-Host "  5. Kill holder process + reset"
        Write-Host "  6. Restart explorer.exe (nuclear)"
        Write-Host "  Q. Quit"
        Write-Host ""
        $c = Read-Host "Choice"

        switch ($c) {
            "1" { Show-Banner; Step-Detect; Pause }
            "2" { Show-Banner; Step-OleReset; Pause }
            "3" { Show-Banner; Step-Win32Reset; Pause }
            "4" { Show-Banner; Do-FullFix; Pause }
            "5" { Show-Banner; Step-KillHolder; Start-Sleep -Seconds 1; Step-OleReset | Out-Null; Pause }
            "6" { Show-Banner; Step-ResetExplorer; Pause }
            "q" { break }
            "Q" { break }
        }
    } while ($true)
}

# 无参数时显示菜单；有 -auto 参数时直接执行自动修复
if ($args -contains "-auto") {
    Do-FullFix
} else {
    Show-Menu
}
