<#
  test_BlockGameViewerClipboard.ps1  --  Test Script
  Goal: Prevent GameViewer from using clipboard via API hook
  Method: Patch OpenClipboard in GameViewer's memory to return FALSE
  Usage:
    .\test_BlockGameViewerClipboard.ps1 -Block     Block GameViewer clipboard
    .\test_BlockGameViewerClipboard.ps1 -Unblock   Restore original function
    .\test_BlockGameViewerClipboard.ps1 -Status    Show status
    .\test_BlockGameViewerClipboard.ps1 -Monitor   Continuous monitoring (default)
    .\test_BlockGameViewerClipboard.ps1            default = -Monitor
  Note:
  - Run as Administrator (required for WriteProcessMemory)
  - Patch is in-memory only; restart GameViewer to restore
  - Use 64-bit PowerShell (default on 64-bit Windows)
#>

param(
    [switch]$Block,
    [switch]$Unblock,
    [switch]$Status,
    [switch]$Monitor
)

# ========== C# core: API Hook via memory patching ==========
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Collections.Generic;
using System.Text;

public class ClipboardHacker
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress,
        byte[] lpBuffer, uint nSize, out uint lpNumberOfBytesWritten);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress,
        byte[] lpBuffer, uint dwSize, out uint lpNumberOfBytesRead);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool VirtualProtectEx(IntPtr hProcess, IntPtr lpAddress,
        uint dwSize, uint flNewProtect, out uint lpflOldProtect);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);

    [DllImport("kernel32.dll")]
    public static extern bool IsWow64Process(IntPtr hProcess, out bool wow64Process);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool Module32First(IntPtr hSnapshot, ref MODULEENTRY32 lpme);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool Module32Next(IntPtr hSnapshot, ref MODULEENTRY32 lpme);

    public const uint TH32CS_SNAPMODULE = 0x00000008;
    public const uint TH32CS_SNAPMODULE32 = 0x00000010;
    public static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MODULEENTRY32
    {
        public uint dwSize;
        public uint th32ModuleID;
        public uint th32ProcessID;
        public uint GlblcntUsage;
        public uint ProccntUsage;
        public IntPtr modBaseAddr;
        public uint modBaseSize;
        public IntPtr hModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExePath;
    }

    public const uint PROCESS_VM_READ      = 0x0010;
    public const uint PROCESS_VM_WRITE     = 0x0020;
    public const uint PROCESS_VM_OPERATION = 0x0008;
    public const uint PROCESS_QUERY_INFORMATION = 0x0400;
    public static readonly uint PROCESS_RW = PROCESS_VM_READ | PROCESS_VM_WRITE
                                           | PROCESS_VM_OPERATION | PROCESS_QUERY_INFORMATION;
    const uint PAGE_EXECUTE_READWRITE = 0x40;

    // patch: xor eax, eax; ret         (x64, 3 bytes)
    public static readonly byte[] PatchX64 = new byte[] { 0x33, 0xC0, 0xC3 };
    // patch: xor eax, eax; ret 4       (x86 stdcall, 5 bytes)
    public static readonly byte[] PatchX86 = new byte[] { 0x33, 0xC0, 0xC2, 0x04, 0x00 };

    public static int[] FindPids()
    {
        var list = new List<int>();
        foreach (var p in Process.GetProcesses())
        {
            try
            {
                string name = p.ProcessName;
                if (name.IndexOf("GameViewer", StringComparison.OrdinalIgnoreCase) >= 0)
                    list.Add(p.Id);
            }
            catch { }
        }
        return list.ToArray();
    }

    public static string CheckBitnessWarning(int pid)
    {
        if (IntPtr.Size != 8)
        {
            IntPtr hProc = OpenProcess(PROCESS_QUERY_INFORMATION, false, (uint)pid);
            if (hProc != IntPtr.Zero)
            {
                bool isWow64 = true;
                IsWow64Process(hProc, out isWow64);
                CloseHandle(hProc);
                if (!isWow64)
                {
                    return "WARNING: PowerShell is 32-bit, cannot patch 64-bit process.\n" +
                           "Use 64-bit PowerShell (default).";
                }
            }
        }
        return null;
    }

    private static IntPtr GetUser32BaseInTarget(int pid)
    {
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, (uint)pid);
        if (snapshot == INVALID_HANDLE_VALUE)
            return IntPtr.Zero;

        try
        {
            MODULEENTRY32 me = new MODULEENTRY32();
            me.dwSize = (uint)Marshal.SizeOf(typeof(MODULEENTRY32));

            if (Module32First(snapshot, ref me))
            {
                do
                {
                    if (me.szModule.Equals("user32.dll", StringComparison.OrdinalIgnoreCase))
                        return me.modBaseAddr;
                } while (Module32Next(snapshot, ref me));
            }
            return IntPtr.Zero;
        }
        finally
        {
            CloseHandle(snapshot);
        }
    }

    public static PatchResult ApplyPatch(int pid)
    {
        var result = new PatchResult();
        result.Pid = pid;
        result.Success = false;

        string bitWarn = CheckBitnessWarning(pid);
        if (bitWarn != null)
        {
            result.ErrorMsg = bitWarn;
            return result;
        }

        IntPtr hProcess = OpenProcess(PROCESS_RW, false, (uint)pid);
        if (hProcess == IntPtr.Zero)
        {
            int err = Marshal.GetLastWin32Error();
            result.ErrorMsg = "OpenProcess(PID=" + pid + ") failed (err=" + err + "). Run as Admin.";
            return result;
        }

        try
        {
            bool isWow64;
            IsWow64Process(hProcess, out isWow64);
            result.IsWow64 = isWow64;

            byte[] patch = isWow64 ? PatchX86 : PatchX64;
            string bitStr = isWow64 ? "x86" : "x64";

            IntPtr localUser32 = GetModuleHandle("user32.dll");
            if (localUser32 == IntPtr.Zero)
            {
                result.ErrorMsg = "Cannot get user32.dll handle";
                return result;
            }

            IntPtr user32Base = GetUser32BaseInTarget(pid);
            if (user32Base == IntPtr.Zero)
            {
                // fallback: use local address (works when same bitness)
                user32Base = localUser32;
            }

            IntPtr localFunc = GetProcAddress(localUser32, "OpenClipboard");
            if (localFunc == IntPtr.Zero)
            {
                result.ErrorMsg = "Cannot get OpenClipboard function address";
                return result;
            }

            // RVA = local function addr - local user32 base
            long rva = localFunc.ToInt64() - localUser32.ToInt64();
            IntPtr targetFuncAddr = new IntPtr(user32Base.ToInt64() + rva);

            result.BackupBytes = new byte[patch.Length];
            uint bytesRead;
            if (!ReadProcessMemory(hProcess, targetFuncAddr, result.BackupBytes, (uint)patch.Length, out bytesRead))
            {
                result.ErrorMsg = "ReadProcessMemory failed (err=" + Marshal.GetLastWin32Error() + ")";
                return result;
            }

            uint oldProtect;
            if (!VirtualProtectEx(hProcess, targetFuncAddr, (uint)patch.Length, PAGE_EXECUTE_READWRITE, out oldProtect))
            {
                result.ErrorMsg = "VirtualProtectEx failed (err=" + Marshal.GetLastWin32Error() + ")";
                return result;
            }

            uint bytesWritten;
            if (!WriteProcessMemory(hProcess, targetFuncAddr, patch, (uint)patch.Length, out bytesWritten))
            {
                result.ErrorMsg = "WriteProcessMemory failed (err=" + Marshal.GetLastWin32Error() + ")";
                VirtualProtectEx(hProcess, targetFuncAddr, (uint)patch.Length, oldProtect, out oldProtect);
                return result;
            }

            VirtualProtectEx(hProcess, targetFuncAddr, (uint)patch.Length, oldProtect, out oldProtect);

            result.Success = true;
            result.TargetAddr = targetFuncAddr;
            result.PatchBytes = patch;
            result.BitStr = bitStr;
            result.OriginalBytesHex = BitConverter.ToString(result.BackupBytes);
            return result;
        }
        catch (Exception ex)
        {
            result.ErrorMsg = "Exception: " + ex.Message;
            return result;
        }
        finally
        {
            CloseHandle(hProcess);
        }
    }

    public static bool RestorePatch(int pid, byte[] originalBytes, out string errorMsg)
    {
        errorMsg = null;

        IntPtr localUser32 = GetModuleHandle("user32.dll");
        IntPtr localFunc = GetProcAddress(localUser32, "OpenClipboard");
        long rva = localFunc.ToInt64() - localUser32.ToInt64();

        IntPtr targetBase = GetUser32BaseInTarget(pid);
        if (targetBase == IntPtr.Zero)
            targetBase = localUser32;

        IntPtr targetAddr = new IntPtr(targetBase.ToInt64() + rva);

        IntPtr hProcess = OpenProcess(PROCESS_RW, false, (uint)pid);
        if (hProcess == IntPtr.Zero)
        {
            errorMsg = "OpenProcess(PID=" + pid + ") failed (err=" + Marshal.GetLastWin32Error() + ")";
            return false;
        }

        try
        {
            uint oldProtect;
            VirtualProtectEx(hProcess, targetAddr, (uint)originalBytes.Length, PAGE_EXECUTE_READWRITE, out oldProtect);

            uint written;
            if (!WriteProcessMemory(hProcess, targetAddr, originalBytes, (uint)originalBytes.Length, out written))
            {
                errorMsg = "Restore failed (err=" + Marshal.GetLastWin32Error() + ")";
                return false;
            }

            VirtualProtectEx(hProcess, targetAddr, (uint)originalBytes.Length, oldProtect, out oldProtect);
            return true;
        }
        finally
        {
            CloseHandle(hProcess);
        }
    }

    public static string GetClipboardInfo()
    {
        IntPtr hOpen = NativeMethods.GetOpenClipboardWindow();
        if (hOpen == IntPtr.Zero || !NativeMethods.IsWindow(hOpen))
            return "FREE";

        uint pid;
        NativeMethods.GetWindowThreadProcessId(hOpen, out pid);
        int len = NativeMethods.GetWindowTextLength(hOpen);
        var sb = new StringBuilder(len + 1);
        NativeMethods.GetWindowText(hOpen, sb, sb.Capacity);
        return "BLOCKED: PID=" + pid + " Title='" + sb.ToString() + "'";
    }
}

public class PatchResult
{
    public int Pid { get; set; }
    public bool Success { get; set; }
    public string ErrorMsg { get; set; }
    public byte[] BackupBytes { get; set; }
    public byte[] PatchBytes { get; set; }
    public IntPtr TargetAddr { get; set; }
    public bool IsWow64 { get; set; }
    public string BitStr { get; set; }
    public string OriginalBytesHex { get; set; }
}

internal class NativeMethods
{
    [DllImport("user32.dll")] public static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder t, int max);
}
"@

# ========== Global state ==========
$script:blockedPids = @{}   # PID -> PatchResult (with backup)

# ========== Helper functions ==========
function Write-Step {
    param([string]$msg, [string]$color = "White")
    $t = Get-Date -Format "HH:mm:ss"
    Write-Host ("[$t] $msg") -ForegroundColor $color
}

function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-Status {
    $gvPids = [ClipboardHacker]::FindPids()
    $clip = [ClipboardHacker]::GetClipboardInfo()

    Write-Host ""
    Write-Host "  +------------------------------------------" -ForegroundColor Cyan
    Write-Host "  | Clipboard: " -NoNewline -ForegroundColor Cyan
    if ($clip -eq "FREE") {
        Write-Host "FREE" -ForegroundColor Green
    } else {
        Write-Host "BLOCKED" -ForegroundColor Red
        Write-Host "  |  $clip" -ForegroundColor Yellow
    }
    Write-Host "  +------------------------------------------" -ForegroundColor Cyan

    if ($gvPids.Length -eq 0) {
        Write-Host "  |  GameViewer: not found" -ForegroundColor Yellow
    } else {
        foreach ($gvPid in $gvPids) {
            try {
                $p = Get-Process -Id $gvPid -ErrorAction Stop
                $blocked = "[unblocked]"
                if ($script:blockedPids.ContainsKey($gvPid)) {
                    $blocked = "[BLOCKED: " + $script:blockedPids[$gvPid].BitStr + "]"
                }
                Write-Host ("  |  GameViewer: PID=" + $gvPid + "  " + $blocked) -ForegroundColor Cyan
            } catch {
                Write-Host ("  |  GameViewer: PID=" + $gvPid + "  [gone]") -ForegroundColor DarkYellow
            }
        }
    }
    Write-Host "  +------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
}

function Invoke-Block {
    param([int]$gvPid)
    $result = [ClipboardHacker]::ApplyPatch($gvPid)
    if ($result.Success) {
        $script:blockedPids[$gvPid] = $result
        Write-Step ("  => BLOCKED PID=" + $gvPid + "  (" + $result.BitStr + ")  orig: " + $result.OriginalBytesHex) "Green"
        return $true
    } else {
        Write-Step ("  => PID=" + $gvPid + "  FAILED: " + $result.ErrorMsg) "Red"
        return $false
    }
}

# ========== Admin check ==========
if (-not (Test-Admin)) {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host "  ADMIN REQUIRED! Run PowerShell as Admin." -ForegroundColor Red
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Right-click PowerShell -> Run as Administrator" -ForegroundColor Yellow
    Write-Host "  Then run: .\" + (Split-Path $MyInvocation.MyCommand.Name -Leaf) -ForegroundColor Yellow
    exit 1
}

# ========== Entry points ==========

if ($Status) {
    Show-Status
    exit
}

if ($Unblock) {
    if ($script:blockedPids.Count -eq 0) {
        Write-Step "No blocked processes in current session memory" "Yellow"
        Write-Step "Restart GameViewer to restore (patch is in-memory only)" "Cyan"
        $gvPids = [ClipboardHacker]::FindPids()
        if ($gvPids.Length -gt 0) {
            Write-Step "Current GameViewer: PID=$gvPids" "Cyan"
            Write-Step "To force restore: restart GameViewer or: taskkill /f /im GameViewer.exe" "Yellow"
        }
        exit
    }

    Write-Step "Restoring GameViewer OpenClipboard function..." "Cyan"
    foreach ($gvPid in $script:blockedPids.Keys) {
        $backup = $script:blockedPids[$gvPid].BackupBytes
        $err = $null
        $ok = [ClipboardHacker]::RestorePatch($gvPid, $backup, [ref]$err)
        if ($ok) {
            Write-Step "  .. PID=$gvPid restored" "Green"
        } else {
            Write-Step "  .. PID=$gvPid restore failed: $err" "Red"
        }
    }
    exit
}

if ($Block) {
    $gvPids = [ClipboardHacker]::FindPids()
    if ($gvPids.Length -eq 0) {
        Write-Step "ERROR: No GameViewer process found" "Red"
        exit 1
    }

    Write-Step "Blocking GameViewer from using clipboard..." "Cyan"
    foreach ($gvPid in $gvPids) {
        Invoke-Block $gvPid | Out-Null
    }

    Start-Sleep -Seconds 1
    $clip = [ClipboardHacker]::GetClipboardInfo()
    if ($clip -eq "FREE") {
        Write-Step "SUCCESS! Clipboard is now FREE." "Green"
    } else {
        Write-Step "Clipboard status: $clip" "Yellow"
        Write-Step "Patch applied but clipboard may still be held (locked before patch)." "Yellow"
        Write-Step "Try force clear:" "Yellow"
        Write-Step "  Add-Type -AssemblyName System.Windows.Forms" "Yellow"
        Write-Step "  [System.Windows.Forms.Clipboard]::Clear()" "Yellow"
    }
    exit
}

if (-not ($Monitor -or $Block -or $Unblock -or $Status)) {
    $Monitor = $true
}

if ($Monitor) {
    $host.UI.RawUI.WindowTitle = "UU Clipboard Blocker - Blocking GameViewer"

    Write-Host ""
    Write-Host "  ========================================================" -ForegroundColor Cyan
    Write-Host "  Clipboard Blocker -- Blocking GameViewer clipboard usage" -ForegroundColor Cyan
    Write-Host "  API Hook: OpenClipboard -> return FALSE" -ForegroundColor Cyan
    Write-Host "  Ctrl+C to exit (process restart auto-restores)" -ForegroundColor Cyan
    Write-Host "  ========================================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Step "Initial scan for GameViewer processes..." "Cyan"
    $gvPids = [ClipboardHacker]::FindPids()
    if ($gvPids.Length -gt 0) {
        foreach ($gvPid in $gvPids) {
            Invoke-Block $gvPid | Out-Null
        }
        Write-Step ("Blocked " + $script:blockedPids.Count + " GameViewer process(es)") "Green"
    } else {
        Write-Step "No GameViewer process found, waiting for new ones..." "Yellow"
    }

    $lastClipStatus = ""
    $lastDisplayTick = 0
    while ($true) {
        Start-Sleep -Seconds 2
        $nowTick = [Environment]::TickCount

        $clip = [ClipboardHacker]::GetClipboardInfo()

        $currentPids = [ClipboardHacker]::FindPids()
        foreach ($gvPid in $currentPids) {
            if (-not $script:blockedPids.ContainsKey($gvPid)) {
                Write-Step "New GameViewer PID=$gvPid detected, blocking..." "Magenta"
                Invoke-Block $gvPid | Out-Null
            }
        }

        $toRemove = @()
        foreach ($gvPid in $script:blockedPids.Keys) {
            if ($gvPid -notin $currentPids) {
                $toRemove += $gvPid
            }
        }
        foreach ($gvPid in $toRemove) {
            $script:blockedPids.Remove($gvPid)
            Write-Step "GameViewer PID=$gvPid exited (auto-restored)" "DarkGray"
        }

        if ($clip -ne $lastClipStatus) {
            if ($clip -eq "FREE") {
                Write-Step ("CLIPBOARD: FREE  (blocking " + $script:blockedPids.Count + " GameViewer)") "Green"
            } else {
                Write-Step ("CLIPBOARD: $clip  (blocking " + $script:blockedPids.Count + " GameViewer)") "Yellow"
            }
            $lastClipStatus = $clip
            $lastDisplayTick = $nowTick
        } elseif ($nowTick - $lastDisplayTick -ge 25000) {
            $icon = if ($clip -eq "FREE") {"OK"} else {"!!"}
            Write-Step ("[$icon] Blocking " + $script:blockedPids.Count + " GameViewer | Clipboard: " + $clip) "DarkGray"
            $lastDisplayTick = $nowTick
        }
    }
}
