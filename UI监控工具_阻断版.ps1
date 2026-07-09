<#
  UU 剪贴板监控工具 - 阻断版
  功能:
  - GUI 界面实时显示剪贴板占用状态（继承自原版）
  - 内存修补 GameViewer 进程的 OpenClipboard 函数 -> return FALSE
  - 自动阻断新启动的 GameViewer 进程
  - 阻断日志实时更新在列表中
  - 支持 -HideConsole 参数隐藏控制台窗口
#>

param(
    [switch]$HideConsole
)

# ========== 隐藏控制台窗口（如果指定了 -HideConsole）==========
if ($HideConsole) {
    try {
        $consoleHandle = (Get-Process -Id $pid).MainWindowHandle
        if ($consoleHandle -ne [IntPtr]::Zero) {
            Add-Type -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
'@ -Namespace NativeMethods -ErrorAction SilentlyContinue
            [NativeMethods.Win32]::ShowWindowAsync($consoleHandle, 0) | Out-Null
        }
    } catch {
        # 忽略隐藏失败
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ========== C# 核心代码：剪贴板检测 + API Hook ==========
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Collections.Generic;
using System.Text;

// ---- 剪贴板检测 API（原版）----
public class ClipUtil {
    [DllImport("user32.dll")] public static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder t, int m);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr hWndNewOwner);
    [DllImport("user32.dll")] public static extern bool CloseClipboard();
    [DllImport("user32.dll")] public static extern bool EmptyClipboard();

    public static string Detect() {
        IntPtr hOpen = GetOpenClipboardWindow();
        if (hOpen != IntPtr.Zero && IsWindow(hOpen)) {
            uint pid; GetWindowThreadProcessId(hOpen, out pid);
            int L = GetWindowTextLength(hOpen);
            var sb = new StringBuilder(L + 1);
            GetWindowText(hOpen, sb, sb.Capacity);
            return "BLOCKED: HWND=" + hOpen + " PID=" + pid + " Title='" + sb.ToString() + "'";
        }
        return "FREE";
    }

    public static bool IsFree() {
        IntPtr h = GetOpenClipboardWindow();
        return h == IntPtr.Zero || !IsWindow(h);
    }

    public static bool IsGameViewerProcess(int pid) {
        try {
            var p = Process.GetProcessById(pid);
            return p.ProcessName.IndexOf("GameViewer", StringComparison.OrdinalIgnoreCase) >= 0;
        } catch { return false; }
    }

    public static bool TryForceRelease() {
        for (int i = 0; i < 5; i++) {
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

// ---- API Hook 阻断（新增）----
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
    public struct MODULEENTRY32 {
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

    public static readonly byte[] PatchX64 = new byte[] { 0x33, 0xC0, 0xC3 };
    public static readonly byte[] PatchX86 = new byte[] { 0x33, 0xC0, 0xC2, 0x04, 0x00 };

    public static int[] FindPids() {
        var list = new List<int>();
        foreach (var p in Process.GetProcesses()) {
            try {
                if (p.ProcessName.IndexOf("GameViewer", StringComparison.OrdinalIgnoreCase) >= 0)
                    list.Add(p.Id);
            } catch { }
        }
        return list.ToArray();
    }

    public static string CheckBitnessWarning(int pid) {
        if (IntPtr.Size != 8) {
            IntPtr hProc = OpenProcess(PROCESS_QUERY_INFORMATION, false, (uint)pid);
            if (hProc != IntPtr.Zero) {
                bool isWow64 = true;
                IsWow64Process(hProc, out isWow64);
                CloseHandle(hProc);
                if (!isWow64)
                    return "32-bit PowerShell cannot patch 64-bit process.";
            }
        }
        return null;
    }

    private static IntPtr GetUser32BaseInTarget(int pid) {
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, (uint)pid);
        if (snapshot == INVALID_HANDLE_VALUE)
            return IntPtr.Zero;
        try {
            MODULEENTRY32 me = new MODULEENTRY32();
            me.dwSize = (uint)Marshal.SizeOf(typeof(MODULEENTRY32));
            if (Module32First(snapshot, ref me)) {
                do {
                    if (me.szModule.Equals("user32.dll", StringComparison.OrdinalIgnoreCase))
                        return me.modBaseAddr;
                } while (Module32Next(snapshot, ref me));
            }
            return IntPtr.Zero;
        } finally { CloseHandle(snapshot); }
    }

    public static PatchResult ApplyPatch(int pid) {
        var result = new PatchResult();
        result.Pid = pid;
        result.Success = false;

        string bitWarn = CheckBitnessWarning(pid);
        if (bitWarn != null) { result.ErrorMsg = bitWarn; return result; }

        IntPtr hProcess = OpenProcess(PROCESS_RW, false, (uint)pid);
        if (hProcess == IntPtr.Zero) {
            int err = Marshal.GetLastWin32Error();
            result.ErrorMsg = "OpenProcess failed (err=" + err + "). Run as Admin.";
            return result;
        }

        try {
            bool isWow64;
            IsWow64Process(hProcess, out isWow64);
            result.IsWow64 = isWow64;
            byte[] patch = isWow64 ? PatchX86 : PatchX64;
            string bitStr = isWow64 ? "x86" : "x64";

            IntPtr localUser32 = GetModuleHandle("user32.dll");
            if (localUser32 == IntPtr.Zero) {
                result.ErrorMsg = "Cannot get user32.dll handle";
                return result;
            }

            IntPtr user32Base = GetUser32BaseInTarget(pid);
            if (user32Base == IntPtr.Zero) user32Base = localUser32;

            IntPtr localFunc = GetProcAddress(localUser32, "OpenClipboard");
            if (localFunc == IntPtr.Zero) {
                result.ErrorMsg = "Cannot get OpenClipboard address";
                return result;
            }

            long rva = localFunc.ToInt64() - localUser32.ToInt64();
            IntPtr targetFuncAddr = new IntPtr(user32Base.ToInt64() + rva);

            result.BackupBytes = new byte[patch.Length];
            uint bytesRead;
            if (!ReadProcessMemory(hProcess, targetFuncAddr, result.BackupBytes, (uint)patch.Length, out bytesRead)) {
                result.ErrorMsg = "ReadProcessMemory failed (err=" + Marshal.GetLastWin32Error() + ")";
                return result;
            }

            uint oldProtect;
            if (!VirtualProtectEx(hProcess, targetFuncAddr, (uint)patch.Length, PAGE_EXECUTE_READWRITE, out oldProtect)) {
                result.ErrorMsg = "VirtualProtectEx failed (err=" + Marshal.GetLastWin32Error() + ")";
                return result;
            }

            uint bytesWritten;
            if (!WriteProcessMemory(hProcess, targetFuncAddr, patch, (uint)patch.Length, out bytesWritten)) {
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
        } catch (Exception ex) {
            result.ErrorMsg = "Exception: " + ex.Message;
            return result;
        } finally { CloseHandle(hProcess); }
    }

    public static string GetClipboardInfo() {
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

public class PatchResult {
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

internal class NativeMethods {
    [DllImport("user32.dll")] public static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder t, int max);
}
"@

# ========== 全局变量 ==========
$script:prevBlockedPid = $null      # 上次占用进程的 PID
$script:lastStatus = "FREE"         # 上次剪贴板状态
$script:blockedPids = @{}           # PID -> PatchResult（已阻断的 GameViewer）

# ========== 开机自启动函数 ==========
$script:MyScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

function Get-AutoStartStatus {
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    return ($null -ne $items -and $null -ne $items."UU剪贴板监控工具")
}

function Set-AutoStart {
    param([bool]$enable)
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if ($enable) {
        # 阻断版指定 -HideConsole 后台运行
        $cmd = 'powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script:MyScriptPath + '" -HideConsole'
        Set-ItemProperty -Path $path -Name "UU剪贴板监控工具" -Value $cmd -Force
    } else {
        Remove-ItemProperty -Path $path -Name "UU剪贴板监控工具" -ErrorAction SilentlyContinue
    }
}

# ========== 构建 UI ==========
$form = New-Object System.Windows.Forms.Form
$form.Text = "UU 剪贴板监控工具 - 阻断版"
$form.Size = New-Object System.Drawing.Size(800, 500)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(680, 380)
$form.Padding = New-Object System.Windows.Forms.Padding(0)
$form.BackColor = [System.Drawing.Color]::White
$form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $pid).Path)

# ========== TableLayoutPanel 三行布局 ==========
$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = "Fill"
$layout.ColumnCount = 1
$layout.RowCount = 3
$layout.RowStyles.Clear()
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 34)))   # 行0: 顶部信息栏
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 100)))   # 行1: 列表
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 28)))   # 行2: 底部状态栏
$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle("Percent", 100)))
$layout.Margin = New-Object System.Windows.Forms.Padding(0)
$layout.Padding = New-Object System.Windows.Forms.Padding(0)

# --- 顶部信息面板（行0）---
$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = "Fill"
$topPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 250)
$topPanel.BorderStyle = "FixedSingle"
$topPanel.Margin = New-Object System.Windows.Forms.Padding(0)

$lblMonitorInfo = New-Object System.Windows.Forms.Label
$lblMonitorInfo.Text = "监控+阻断中... 检测间隔: 3秒 | GameViewer 的 OpenClipboard 已被修补 -> return FALSE"
$lblMonitorInfo.Dock = "Fill"
$lblMonitorInfo.TextAlign = "MiddleLeft"
$lblMonitorInfo.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$lblMonitorInfo.ForeColor = [System.Drawing.Color]::DimGray
$topPanel.Controls.Add($lblMonitorInfo)

# --- 开机自启动勾选框 ---
$chkAutoStart = New-Object System.Windows.Forms.CheckBox
$chkAutoStart.Text = "  开机自启动"
$chkAutoStart.Dock = "Right"
$chkAutoStart.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$chkAutoStart.ForeColor = [System.Drawing.Color]::DimGray
$chkAutoStart.Padding = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$chkAutoStart.TextAlign = "MiddleLeft"
$chkAutoStart.Checked = Get-AutoStartStatus
$chkAutoStart.Add_CheckedChanged({
    try {
        Set-AutoStart -enable ($this.Checked)
        $statusLabel.Text = if ($this.Checked) { "已设置开机自启动" } else { "已取消开机自启动" }
        $statusLabel.ForeColor = [System.Drawing.Color]::Green
    } catch {
        $statusLabel.Text = "设置开机自启动失败: " + $_.Exception.Message
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
    }
})
$topPanel.Controls.Add($chkAutoStart)

$layout.Controls.Add($topPanel, 0, 0)

# --- ListView 显示日志（行1）---
$listView = New-Object System.Windows.Forms.ListView
$listView.Dock = "Fill"
$listView.View = "Details"
$listView.FullRowSelect = $true
$listView.GridLines = $true
$listView.MultiSelect = $false
$listView.Font = New-Object System.Drawing.Font("Consolas", 10)
$listView.Margin = New-Object System.Windows.Forms.Padding(0)

# 列定义（增加一列备注）
$listView.Columns.Add("时间", 80, "Left")
$listView.Columns.Add("状态", 80, "Center")
$listView.Columns.Add("进程名", 160, "Left")
$listView.Columns.Add("PID", 80, "Right")
$listView.Columns.Add("详细信息", 360, "Left")

# --- 右键菜单 ---
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuRestart = New-Object System.Windows.Forms.ToolStripMenuItem
$menuRestart.Text = "[重启] 重启进程"
$contextMenu.Items.Add($menuRestart) | Out-Null
$menuKill = New-Object System.Windows.Forms.ToolStripMenuItem
$menuKill.Text = "[结束] 结束进程 (Kill)"
$contextMenu.Items.Add($menuKill) | Out-Null
$contextMenu.Items.Add("-") | Out-Null  # 分隔线
$menuCopyInfo = New-Object System.Windows.Forms.ToolStripMenuItem
$menuCopyInfo.Text = "[复制] 复制进程信息"
$contextMenu.Items.Add($menuCopyInfo) | Out-Null
$listView.ContextMenuStrip = $contextMenu

$layout.Controls.Add($listView, 0, 1)

# --- 底部状态栏（行2）---
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.Dock = "Fill"
$statusStrip.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$statusStrip.SizingGrip = $false
$statusStrip.Margin = New-Object System.Windows.Forms.Padding(0)
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "正在初始化..."
$statusLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = [System.Drawing.Color]::RoyalBlue
$statusStrip.Items.Add($statusLabel) | Out-Null

# --- 阻断计数标签 ---
$blockCountLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$blockCountLabel.Text = ""
$blockCountLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$blockCountLabel.ForeColor = [System.Drawing.Color]::DimGray
$blockCountLabel.Spring = $true
$blockCountLabel.TextAlign = "MiddleRight"
$statusStrip.Items.Add($blockCountLabel) | Out-Null

$layout.Controls.Add($statusStrip, 0, 2)

$form.Controls.Add($layout)

# ========== 辅助函数 ==========
function Add-LogEntry {
    param([string]$time, [string]$status, [string]$procName, [string]$procId, [string]$detail)

    $item = New-Object System.Windows.Forms.ListViewItem($time)
    $item.SubItems.Add($status) | Out-Null
    $item.SubItems.Add($procName) | Out-Null
    $item.SubItems.Add($procId) | Out-Null
    $item.SubItems.Add($detail) | Out-Null

    # 颜色标识
    switch ($status) {
        "LOCKED" {
            $item.BackColor = [System.Drawing.Color]::MistyRose
            $item.ForeColor = [System.Drawing.Color]::DarkRed
        }
        "FREE" {
            $item.BackColor = [System.Drawing.Color]::Honeydew
            $item.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        "HOOKED" {
            $item.BackColor = [System.Drawing.Color]::Lavender
            $item.ForeColor = [System.Drawing.Color]::DarkBlue
        }
        "BLOCK_FAIL" {
            $item.BackColor = [System.Drawing.Color]::LightSalmon
            $item.ForeColor = [System.Drawing.Color]::DarkRed
        }
        "RESTART" {
            $item.BackColor = [System.Drawing.Color]::LightCyan
            $item.ForeColor = [System.Drawing.Color]::DarkBlue
        }
        "KILLED" {
            $item.BackColor = [System.Drawing.Color]::LightSalmon
            $item.ForeColor = [System.Drawing.Color]::DarkRed
        }
        default {
            $item.BackColor = [System.Drawing.Color]::White
            $item.ForeColor = [System.Drawing.Color]::Black
        }
    }

    # 保留最近 300 条记录
    if ($listView.Items.Count -ge 300) {
        $listView.Items.RemoveAt(0)
    }

    $listView.Items.Add($item) | Out-Null
    $item.EnsureVisible()
}

function Write-Step {
    param([string]$msg, [string]$color = "White")
    $t = Get-Date -Format "HH:mm:ss"
    Write-Host ("[$t] $msg") -ForegroundColor $color
}

function Update-StatusBar {
    $count = $script:blockedPids.Count
    $clipStatus = if ([ClipUtil]::IsFree()) { "FREE" } else { "LOCKED" }
    if ($count -gt 0) {
        $blockCountLabel.Text = "已阻断 " + $count + " 个 GameViewer 进程"
        $blockCountLabel.ForeColor = [System.Drawing.Color]::Green
    } else {
        $blockCountLabel.Text = "未发现 GameViewer 进程"
        $blockCountLabel.ForeColor = [System.Drawing.Color]::DimGray
    }
}

# ========== 阻断逻辑 ==========
function Invoke-BlockGameViewer {
    $pids = [ClipboardHacker]::FindPids()
    $newlyBlocked = 0

    foreach ($gvPid in $pids) {
        if (-not $script:blockedPids.ContainsKey($gvPid)) {
            # 尚未阻断，执行修补
            $result = [ClipboardHacker]::ApplyPatch($gvPid)
            $t = Get-Date -Format "HH:mm:ss"

            if ($result.Success) {
                $script:blockedPids[$gvPid] = $result
                Add-LogEntry $t "HOOKED" ("GameViewer (PID=" + $gvPid + ")") $gvPid ("修补成功 " + $result.BitStr + " | 原始: " + $result.OriginalBytesHex)
                $newlyBlocked++
            } else {
                Add-LogEntry $t "BLOCK_FAIL" ("GameViewer (PID=" + $gvPid + ")") $gvPid ("修补失败: " + $result.ErrorMsg)
            }
        }
    }

    # 清理已退出的进程
    $toRemove = @()
    foreach ($id in $script:blockedPids.Keys) {
        if ($id -notin $pids) {
            $toRemove += $id
        }
    }
    foreach ($id in $toRemove) {
        $t = Get-Date -Format "HH:mm:ss"
        Add-LogEntry $t "INFO" ("GameViewer (PID=" + $id + ")") $id "进程已退出，阻断自动解除"
        $script:blockedPids.Remove($id)
    }

    Update-StatusBar

    if ($newlyBlocked -gt 0) {
        # 新阻断了一个进程，如果剪贴板被占用且是 GameViewer，尝试释放
        $info = [ClipUtil]::Detect()
        if ($info -match 'PID=(\d+)') {
            $blockerPid = [int]$matches[1]
            if ([ClipUtil]::IsGameViewerProcess($blockerPid)) {
                $t = Get-Date -Format "HH:mm:ss"
                Add-LogEntry $t "INFO" "尝试释放" $blockerPid "GameViewer 已被阻断，尝试清空剪贴板"
                $ok = [ClipUtil]::TryForceRelease()
                if ($ok) {
                    Add-LogEntry $t "FREE" "-" "-" "剪贴板已强制释放"
                }
            }
        }
    }

    return $newlyBlocked
}

# ========== 检测函数（每次定时器触发）==========
function Invoke-ClipboardCheck {
    $t = Get-Date -Format "HH:mm:ss"
    $info = [ClipUtil]::Detect()
    $isFree = ($info -eq "FREE")

    if ($isFree) {
        if ($script:lastStatus -ne "FREE") {
            Add-LogEntry $t "FREE" "-" "-" "剪贴板已释放"
            $statusLabel.Text = "剪贴板空闲"
            $statusLabel.ForeColor = [System.Drawing.Color]::Green
        }
        $script:prevBlockedPid = $null
        $script:lastStatus = "FREE"
    } else {
        if ($info -match 'PID=(\d+)') {
            $procId = $matches[1]
            $titleMatch = $info -match "Title='(.*)'"
            $windowTitle = if ($titleMatch) { $matches[1] } else { "未知" }

            try {
                $p = Get-Process -Id $procId -ErrorAction Stop
                $procName = $p.ProcessName

                if ($script:prevBlockedPid -ne $procId) {
                    Add-LogEntry $t "LOCKED" $procName $procId $windowTitle
                    $statusLabel.Text = ("剪贴板被占用: " + $procName + " (PID=" + $procId + ")")
                    $statusLabel.ForeColor = [System.Drawing.Color]::Red
                    $script:prevBlockedPid = $procId
                }
            } catch {
                if ($script:prevBlockedPid -ne $procId) {
                    Add-LogEntry $t "LOCKED" "进程已消失" $procId $windowTitle
                    $statusLabel.Text = ("剪贴板被占用 (进程已消失, PID=" + $procId + ")")
                    $statusLabel.ForeColor = [System.Drawing.Color]::Orange
                    $script:prevBlockedPid = $procId
                }
            }
        }
        $script:lastStatus = "LOCKED"
    }

    Update-StatusBar
}

# ========== 定时器：每 3 秒执行一次检测+阻断 ==========
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    # 第一步：检查剪贴板状态（原版功能）
    Invoke-ClipboardCheck
    # 第二步：阻断 GameViewer（新增功能）
    Invoke-BlockGameViewer | Out-Null
})

# ========== 右键菜单事件 ==========
$menuRestart.Add_Click({
    if ($listView.SelectedItems.Count -gt 0) {
        $item = $listView.SelectedItems[0]
        $status = $item.SubItems[1].Text
        $procName = $item.SubItems[2].Text
        $pidText = $item.SubItems[3].Text

        if ($status -notin @("LOCKED")) {
            [System.Windows.Forms.MessageBox]::Show("只有被占用 (LOCKED) 状态的进程才能重启。", "提示", "OK", "Information")
            return
        }

        if ($pidText -eq "-" -or $pidText -eq "") {
            [System.Windows.Forms.MessageBox]::Show("无效的 PID，无法操作。", "错误", "OK", "Warning")
            return
        }

        $result = [System.Windows.Forms.MessageBox]::Show(
            "确定要重启进程「" + $procName + "」(PID=" + $pidText + ") 吗？",
            "确认重启",
            "YesNo",
            "Question"
        )

        if ($result -eq "Yes") {
            $success = Restart-ProcessByPid -targetPid ([int]$pidText) -procName $procName
            if ($success) { Invoke-ClipboardCheck }
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("请先选中一个进程条目。", "提示", "OK", "Information")
    }
})

$menuKill.Add_Click({
    if ($listView.SelectedItems.Count -gt 0) {
        $item = $listView.SelectedItems[0]
        $status = $item.SubItems[1].Text
        $procName = $item.SubItems[2].Text
        $pidText = $item.SubItems[3].Text

        if ($status -notin @("LOCKED")) {
            [System.Windows.Forms.MessageBox]::Show("只有被占用 (LOCKED) 状态的进程才能结束。", "提示", "OK", "Information")
            return
        }
        if ($pidText -eq "-" -or $pidText -eq "") {
            [System.Windows.Forms.MessageBox]::Show("无效的 PID，无法操作。", "错误", "OK", "Warning")
            return
        }

        $result = [System.Windows.Forms.MessageBox]::Show(
            "确定要结束进程「" + $procName + "」(PID=" + $pidText + ") 吗？",
            "确认结束进程",
            "YesNo",
            "Warning"
        )

        if ($result -eq "Yes") {
            try {
                $p = Get-Process -Id ([int]$pidText) -ErrorAction Stop
                $p.Kill()
                $p.WaitForExit(3000)
                $t = Get-Date -Format "HH:mm:ss"
                Add-LogEntry $t "KILLED" $procName $pidText "进程已终止"
                $statusLabel.Text = "已终止: " + $procName
                $statusLabel.ForeColor = [System.Drawing.Color]::Orange
                Invoke-ClipboardCheck
            } catch {
                [System.Windows.Forms.MessageBox]::Show("结束进程失败: " + $_.Exception.Message, "错误", "OK", "Error")
            }
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("请先选中一个进程条目。", "提示", "OK", "Information")
    }
})

$menuCopyInfo.Add_Click({
    if ($listView.SelectedItems.Count -gt 0) {
        $item = $listView.SelectedItems[0]
        $text = "时间: " + $item.SubItems[0].Text + "`n"
        $text += "状态: " + $item.SubItems[1].Text + "`n"
        $text += "进程名: " + $item.SubItems[2].Text + "`n"
        $text += "PID: " + $item.SubItems[3].Text + "`n"
        $text += "详细信息: " + $item.SubItems[4].Text

        [System.Windows.Forms.Clipboard]::SetText($text)
        [System.Windows.Forms.MessageBox]::Show("进程信息已复制到剪贴板。", "提示", "OK", "Information")
    }
})

# ========== 窗口关闭事件 ==========
$form.Add_FormClosing({
    param($sender, $e)
    $timer.Stop()
    $result = [System.Windows.Forms.MessageBox]::Show(
        "确认退出剪贴板监控工具（阻断版）？`n退出后 GameViewer 将可重新锁定剪贴板。",
        "退出确认",
        "YesNo",
        "Question"
    )
    if ($result -eq "No") {
        $e.Cancel = $true
        $timer.Start()
    }
})

# ========== 启动 ==========
Write-Step "UU 剪贴板监控工具（阻断版）启动" "Cyan"
Write-Step "功能: 监控剪贴板 + 自动阻断 GameViewer 进程的 OpenClipboard" "Cyan"
Write-Step "检测间隔: 3秒 | 右键列表项可重启/结束占用进程" "Cyan"

# 添加启动记录
$t = Get-Date -Format "HH:mm:ss"
Add-LogEntry $t "INFO" "阻断版" "-" "启动监控+阻断..."
$statusLabel.Text = "正在初始化..."
$statusLabel.ForeColor = [System.Drawing.Color]::RoyalBlue

# 启动时立即执行一次检测+阻断
Invoke-BlockGameViewer | Out-Null
Invoke-ClipboardCheck

$timer.Start()

# 运行窗体
[System.Windows.Forms.Application]::Run($form)
