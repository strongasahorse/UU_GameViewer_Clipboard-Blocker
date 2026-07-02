<#
UU Remote Clipboard Reset - Core Script
Usage:
  .\方案2_核心.ps1 -detect          : detect clipboard owner
  .\方案2_核心.ps1 -reset           : reset clipboard via OLE
  .\方案2_核心.ps1 -kill            : kill holder process + reset
  .\方案2_核心.ps1 -monitor         : continuous monitor mode (auto reset)
  .\方案2_核心.ps1 -watch           : watch clipboard status only (no reset)
  .\方案2_核心.ps1 -resetexplorer   : restart explorer.exe (nuclear)
#>

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ClipUtil {
    [DllImport("user32.dll")] public static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetClipboardOwner();
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

function Write-Step {
    param([string]$msg, [string]$color = "White")
    $t = Get-Date -Format "HH:mm:ss"
    Write-Host ("[$t] $msg") -ForegroundColor $color
}

$action = $args[0]

switch ($action) {
    "-detect" {
        $info = [ClipUtil]::Detect()
        if ($info -eq "FREE") {
            Write-Host "FREE"
            exit 0
        }
        Write-Host $info
        if ($info -match 'PID=(\d+)') {
            $procId = $matches[1]
            try {
                $p = Get-Process -Id $procId -ErrorAction Stop
                Write-Host ("Process: " + $p.ProcessName + " (" + $p.MainWindowTitle + ")")
            } catch {
                Write-Host ("Process: PID=" + $procId + " (not found)")
            }
        }
        exit 1
    }

    "-reset" {
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
                Write-Host "OK" -ForegroundColor Green
                $script:success = $true
            } catch {
                Write-Host ("FAIL: " + $_.Exception.Message) -ForegroundColor Red
                $script:success = $false
            }
            $form.Close()
        })
        [System.Windows.Forms.Application]::Run($form)
        if ($success) { exit 0 } else { exit 1 }
    }

    "-kill" {
        $info = [ClipUtil]::Detect()
        if ($info -eq "FREE") {
            Write-Host "No owner, resetting directly..." -ForegroundColor Cyan
        } else {
            Write-Host ("Owner: " + $info) -ForegroundColor Yellow
            if ($info -match 'PID=(\d+)') {
                $procId = $matches[1]
                try {
                    $p = Get-Process -Id $procId -ErrorAction Stop
                    Write-Host ("Killing: " + $p.ProcessName + " (PID=" + $procId + ")") -ForegroundColor Red
                    $p.Kill()
                    $p.WaitForExit(3000)
                    Start-Sleep -Seconds 1
                } catch {
                    Write-Host ("Cannot kill PID " + $procId + ": " + $_.Exception.Message) -ForegroundColor Red
                    exit 2
                }
            }
        }
        & $PSCommandPath -reset
        exit $LASTEXITCODE
    }

    "-resetexplorer" {
        Write-Step "Restarting explorer.exe..." "Yellow"
        try {
            Get-Process explorer -ErrorAction Stop | Stop-Process -Force
            Start-Sleep -Seconds 3
            Write-Step "Explorer restarted" "Green"
            exit 0
        } catch {
            Write-Step ("Explorer restart FAILED: " + $_.Exception.Message) "Red"
            exit 1
        }
    }

    "-monitor" {
        $host.UI.RawUI.WindowTitle = "UU Clip Monitor - DO NOT CLOSE"
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host "  Continuous Monitor (auto reset)" -ForegroundColor Cyan
        Write-Host "  Ctrl+C to stop" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host ""

        $prevFree = $null
        while ($true) {
            $t = Get-Date -Format "HH:mm:ss"
            $info = [ClipUtil]::Detect()
            $isFree = ($info -eq "FREE")

            if ($isFree) {
                & $PSCommandPath -reset *>$null
                if ($LASTEXITCODE -eq 0) {
                    $msg = "[$t] Auto reset OK - clipboard free"
                } else {
                    $msg = "[$t] Auto reset FAIL"
                }
            } else {
                if ($info -match 'PID=(\d+)') {
                    $procId = $matches[1]
                    try {
                        $p = Get-Process -Id $procId -ErrorAction Stop
                        $msg = "[$t] LOCKED by " + $p.ProcessName + " (PID=" + $procId + ")"
                    } catch {
                        $msg = "[$t] LOCKED by PID=" + $procId + " (process gone)"
                    }
                } else {
                    $msg = "[$t] LOCKED - " + $info
                }
            }

            # FREE: overwrite same line; LOCKED: always new line
            if ($isFree -and $prevFree -eq $true) {
                # Overwrite previous line
                [Console]::CursorTop = [Console]::CursorTop - 1
                Write-Host (" " * 100)  # clear line
                [Console]::CursorTop = [Console]::CursorTop - 1
                Write-Host $msg -ForegroundColor Green
            } else {
                # New line
                if ($isFree) {
                    Write-Host $msg -ForegroundColor Green
                } else {
                    Write-Host $msg -ForegroundColor Yellow
                }
            }
            $prevFree = $isFree

            Start-Sleep -Seconds 10
        }
    }

    "-watch" {
        $host.UI.RawUI.WindowTitle = "UU Clip Watch - press 3=force reset, 6=restart explorer"
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host "  Clipboard Status Monitor" -ForegroundColor Cyan
        Write-Host "  [3] Force reset (kill holder + reset)" -ForegroundColor Cyan
        Write-Host "  [6] Restart explorer.exe (nuclear)" -ForegroundColor Cyan
        Write-Host "  Ctrl+C to stop" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host ""

        function Do-KillReset {
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
                        return
                    }
                }
            }
            & $PSCommandPath -reset
            if ($LASTEXITCODE -eq 0) {
                Write-Host ("[KILL] Reset successful") -ForegroundColor Green
            } else {
                Write-Host ("[KILL] Reset failed") -ForegroundColor Red
            }
        }

        function Do-ResetExplorer {
            Write-Host ("[EXPLORER] Restarting explorer.exe...") -ForegroundColor Yellow
            try {
                Get-Process explorer -ErrorAction Stop | Stop-Process -Force
                Start-Sleep -Seconds 3
                Write-Host ("[EXPLORER] Explorer restarted") -ForegroundColor Green
            } catch {
                Write-Host ("[EXPLORER] Restart FAILED: " + $_.Exception.Message) -ForegroundColor Red
            }
        }

        $lastDisplay = 0
        $prevFree = $null
        while ($true) {
            # Check for key press (non-blocking)
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.KeyChar -eq '3') {
                        Write-Host ""
                        Write-Host "---------------------------------------------" -ForegroundColor Magenta
                        Write-Host "  Force reset triggered!" -ForegroundColor Magenta
                        Write-Host "---------------------------------------------" -ForegroundColor Magenta
                        Do-KillReset
                        Write-Host "---------------------------------------------" -ForegroundColor Magenta
                        Write-Host "  Resuming watch..." -ForegroundColor Magenta
                        Write-Host "---------------------------------------------" -ForegroundColor Magenta
                        $lastDisplay = 0
                        $prevFree = $null
                    } elseif ($key.KeyChar -eq '6') {
                        Write-Host ""
                        Write-Host "---------------------------------------------" -ForegroundColor Magenta
                        Write-Host "  Restarting explorer.exe..." -ForegroundColor Magenta
                        Write-Host "---------------------------------------------" -ForegroundColor Magenta
                        Do-ResetExplorer
                        Write-Host "---------------------------------------------" -ForegroundColor Magenta
                        Write-Host "  Resuming watch..." -ForegroundColor Magenta
                        Write-Host "---------------------------------------------" -ForegroundColor Magenta
                        $lastDisplay = 0
                        $prevFree = $null
                    }
                }
            } catch {
                # stdin redirected, skip key check
            }

            # Display status every 5 seconds
            $now = [Environment]::TickCount
            if ($now - $lastDisplay -ge 5000) {
                $t = Get-Date -Format "HH:mm:ss"
                $info = [ClipUtil]::Detect()
                $isFree = ($info -eq "FREE")

                if ($isFree) {
                    $msg = ("[$t] Free - clipboard available")
                } else {
                    if ($info -match 'PID=(\d+)') {
                        $procId = $matches[1]
                        try {
                            $p = Get-Process -Id $procId -ErrorAction Stop
                            $msg = ("[$t] LOCKED by " + $p.ProcessName + " (PID=" + $procId + ")")
                        } catch {
                            $msg = ("[$t] LOCKED by PID=" + $procId + " (process gone)")
                        }
                    } else {
                        $msg = ("[$t] LOCKED - " + $info)
                    }
                }

                # FREE: overwrite same line; LOCKED: always new line
                if ($isFree -and $prevFree -eq $true) {
                    # Overwrite previous line
                    try {
                        [Console]::CursorTop = [Console]::CursorTop - 1
                        Write-Host (" " * 100)  # clear line
                        [Console]::CursorTop = [Console]::CursorTop - 1
                    } catch {
                        # cursor control may fail in some hosts
                    }
                    Write-Host $msg -ForegroundColor Green
                } else {
                    if ($isFree) {
                        Write-Host $msg -ForegroundColor Green
                    } else {
                        Write-Host $msg -ForegroundColor Yellow
                    }
                }
                $prevFree = $isFree
                $lastDisplay = $now
            }

            Start-Sleep -Milliseconds 500
        }
    }

    default {
        $host.UI.RawUI.WindowTitle = "UU Clip Reset - Option 2"
        do {
            Clear-Host
            Write-Host "============================================"
            Write-Host "  UU Clipboard Reset - Option 2"
            Write-Host "============================================"
            Write-Host ""
            $isFree = [ClipUtil]::IsFree()
            if ($isFree) {
                Write-Host "  Current status: [FREE]" -ForegroundColor Green
            } else {
                $info = [ClipUtil]::GetOwnerInfo()
                Write-Host ("  Current status: [LOCKED] " + $info) -ForegroundColor Red
            }
            Write-Host ""
            Write-Host "  1. Detect clipboard owner"
            Write-Host "  2. Reset clipboard (OLE)"
            Write-Host "  3. Force reset (kill holder + reset)"
            Write-Host "  4. Continuous monitor (auto reset)"
            Write-Host "  5. Watch mode (press 3=kill, 6=explorer)"
            Write-Host "  6. Restart explorer.exe (nuclear)"
            Write-Host "  Q. Quit"
            Write-Host ""
            $c = Read-Host "Choice"

            switch ($c) {
                "1" { & $PSCommandPath -detect; Write-Host ""; Read-Host "Press Enter" }
                "2" { & $PSCommandPath -reset; Write-Host ""; Read-Host "Press Enter" }
                "3" { & $PSCommandPath -kill; Write-Host ""; Read-Host "Press Enter" }
                "4" { & $PSCommandPath -monitor }
                "5" { & $PSCommandPath -watch }
                "6" { & $PSCommandPath -resetexplorer; Write-Host ""; Read-Host "Press Enter" }
            }
        } while ($c -ne "Q" -and $c -ne "q")
    }
}
