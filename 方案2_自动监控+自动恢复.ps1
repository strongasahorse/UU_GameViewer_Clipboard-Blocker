<#
UU Remote Clipboard - Auto Watch + Auto Recovery
基于方案2，直接进入监控模式，自动恢复剪贴板锁�?保留按键 3=强制重置�?=重启explorer
#>

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ClipUtil {
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
}
"@

$host.UI.RawUI.WindowTitle = "UU Auto Watch + Auto Recovery"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Auto Watch + Auto Recovery" -ForegroundColor Cyan
Write-Host "  [A]uto-recovery: ON (default)" -ForegroundColor Cyan
Write-Host "  [3] Force reset (kill holder + reset)" -ForegroundColor Cyan
Write-Host "  [6] Restart explorer.exe (nuclear)" -ForegroundColor Cyan
Write-Host "  Ctrl+C to stop" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

function Do-KillReset {
    Write-Host ("-" * 60) -ForegroundColor Magenta
    Write-Host ("[ACTION] Force reset triggered") -ForegroundColor Magenta
    $info = [ClipUtil]::Detect()
    if ($info -eq "FREE") {
        Write-Host ("[KILL] No owner, resetting directly...") -ForegroundColor Cyan
    } else {
        Write-Host ("[KILL] Owner: " + $info) -ForegroundColor Yellow
        if ($info -match 'PID=(\d+)') {
            $procId = $matches[1]
            try {
                $p = Get-Process -Id $procId -ErrorAction Stop
                Write-Host ("[KILL] Killing: " + $p.ProcessName + " (PID=" + $procId + ")") -ForegroundColor Red
                $p.Kill()
                $p.WaitForExit(3000)
                Start-Sleep -Seconds 1
            } catch {
                Write-Host ("[KILL] Cannot kill PID " + $procId + ": " + $_.Exception.Message) -ForegroundColor Red
                Write-Host ("-" * 60) -ForegroundColor Magenta
                return
            }
        }
    }
    # OLE reset
    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object System.Windows.Forms.Form
    $form.WindowState = "Minimized"
    $form.ShowInTaskbar = $false
    $form.TopMost = $false
    $success = $false
    $form.Add_Shown({
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
        try {
            [System.Windows.Forms.Clipboard]::Clear()
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.Clipboard]::SetText(' ')
            $script:success = $true
        } catch {
            $script:success = $false
        }
        $form.Close()
    })
    [System.Windows.Forms.Application]::Run($form)
    if ($success) {
        Write-Host ("[KILL] Reset successful") -ForegroundColor Green
    } else {
        Write-Host ("[KILL] Reset failed") -ForegroundColor Red
    }
    Write-Host ("-" * 60) -ForegroundColor Magenta
}

function Do-ResetExplorer {
    Write-Host ("-" * 60) -ForegroundColor Magenta
    Write-Host ("[ACTION] Restarting explorer.exe...") -ForegroundColor Yellow
    try {
        Get-Process explorer -ErrorAction Stop | Stop-Process -Force
        Start-Sleep -Seconds 3
        Write-Host ("[EXPLORER] Explorer restarted") -ForegroundColor Green
    } catch {
        Write-Host ("[EXPLORER] Restart FAILED: " + $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host ("-" * 60) -ForegroundColor Magenta
}

$lastDisplay = 0
$prevFree = $null
$autoRecovery = $true

Write-Host "[AUTO] Auto-recovery is ON" -ForegroundColor Green
Write-Host ""

while ($true) {
    # Check for key press (non-blocking)
    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -eq '3') {
                Do-KillReset
                $lastDisplay = 0
                $prevFree = $null
            } elseif ($key.KeyChar -eq '6') {
                Do-ResetExplorer
                $lastDisplay = 0
                $prevFree = $null
            } elseif ($key.KeyChar -eq 'a' -or $key.KeyChar -eq 'A') {
                $autoRecovery = -not $autoRecovery
                if ($autoRecovery) {
                    Write-Host "[AUTO] Auto-recovery turned ON" -ForegroundColor Green
                } else {
                    Write-Host "[AUTO] Auto-recovery turned OFF" -ForegroundColor Yellow
                }
            }
        }
    } catch {
        # stdin redirected, skip key check
    }

    # Check clipboard status
    $now = [Environment]::TickCount
    if ($now - $lastDisplay -ge 5000) {
        $t = Get-Date -Format "HH:mm:ss"
        $info = [ClipUtil]::Detect()
        $isFree = ($info -eq "FREE")

        if ($isFree) {
            $msg = ("[$t] FREE - clipboard available")
            # Overwrite same line if was also free
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
        } else {
            # Locked - always show new line
            if ($info -match 'PID=(\d+)') {
                $procId = $matches[1]
                try {
                    $p = Get-Process -Id $procId -ErrorAction Stop
                    Write-Host ("[$t] LOCKED by " + $p.ProcessName + " (PID=" + $procId + ")") -ForegroundColor Yellow
                } catch {
                    Write-Host ("[$t] LOCKED by PID=" + $procId + " (process gone)") -ForegroundColor Yellow
                }
            } else {
                Write-Host ("[$t] LOCKED - " + $info) -ForegroundColor Yellow
            }
            $prevFree = $false

            # Auto-recovery: execute force reset
            if ($autoRecovery) {
                Write-Host ("[$t] AUTO-RECOVERY triggered") -ForegroundColor Magenta
                Do-KillReset
                # After recovery, show result
                $afterInfo = [ClipUtil]::Detect()
                $afterT = Get-Date -Format "HH:mm:ss"
                if ($afterInfo -eq "FREE") {
                    Write-Host ("[$afterT] Recovery OK - clipboard is now free") -ForegroundColor Green
                    $prevFree = $true
                } else {
                    Write-Host ("[$afterT] Recovery FAILED - clipboard still locked") -ForegroundColor Red
                }
            }
        }
        $lastDisplay = $now
    }

    Start-Sleep -Milliseconds 500
}
