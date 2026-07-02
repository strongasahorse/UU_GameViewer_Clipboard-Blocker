<#
  UU Remote Clipboard Monitor - UI Version
  功能:
  - 启动后直接进入监控模式
  - GUI 界面实时显示剪切板占用状态
  - 鼠标选中进程条目，右键可重启该进程
  - 避免粗暴 Kill，改为 Kill + Start-Process 重启
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
        # 忽略隐藏失败（调试模式下正常显示）
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ========== 引入剪贴板检测 API ==========
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
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

# ========== 全局变量 ==========
$script:prevBlockedPid = $null   # 上次占用进程的 PID，避免重复添加
$script:lastStatus = "FREE"      # 上次状态

# ========== 开机自启动函数 ==========
$script:MyScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

function Get-AutoStartStatus {
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    # 获取所有属性后检查指定名称是否存在，比 -Name 参数更可靠
    $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    return ($null -ne $items -and $null -ne $items."UU剪贴板监控工具")
}

function Set-AutoStart {
    param([bool]$enable)
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if ($enable) {
        $cmd = 'powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script:MyScriptPath + '" -HideConsole'
        Set-ItemProperty -Path $path -Name "UU剪贴板监控工具" -Value $cmd -Force
    } else {
        Remove-ItemProperty -Path $path -Name "UU剪贴板监控工具" -ErrorAction SilentlyContinue
    }
}

# ========== 构建 UI ==========
$form = New-Object System.Windows.Forms.Form
$form.Text = "UU 剪贴板监控工具"
$form.Size = New-Object System.Drawing.Size(720, 500)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(600, 350)
$form.Padding = New-Object System.Windows.Forms.Padding(0)
$form.BackColor = [System.Drawing.Color]::White
$form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $pid).Path)

# ========== TableLayoutPanel 精确三行布局 ==========
$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = "Fill"
$layout.ColumnCount = 1
$layout.RowCount = 3
$layout.RowStyles.Clear()
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 34)))   # 行0: 顶部信息栏
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 100)))   # 行1: 列表（填满剩余）
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
$lblMonitorInfo.Text = "监控中... 检测间隔: 3秒 | 右键列表项可重启/结束占用进程"
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
# 先设置初始状态（此时尚未注册事件，不会误触发写入注册表）
$chkAutoStart.Checked = Get-AutoStartStatus
# 再注册事件，确保用户手动勾选时才写入注册表
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

# --- ListView 显示剪切板占用记录（行1）---
$listView = New-Object System.Windows.Forms.ListView
$listView.Dock = "Fill"
$listView.View = "Details"
$listView.FullRowSelect = $true
$listView.GridLines = $true
$listView.MultiSelect = $false
$listView.Font = New-Object System.Drawing.Font("Consolas", 10)
$listView.Margin = New-Object System.Windows.Forms.Padding(0)

# 列定义
$listView.Columns.Add("时间", 80, "Left")
$listView.Columns.Add("状态", 60, "Center")
$listView.Columns.Add("进程名", 160, "Left")
$listView.Columns.Add("PID", 80, "Right")
$listView.Columns.Add("窗口标题", 300, "Left")

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
$statusLabel.Text = "正在监控剪贴板..."
$statusLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = [System.Drawing.Color]::RoyalBlue
$statusStrip.Items.Add($statusLabel) | Out-Null
$layout.Controls.Add($statusStrip, 0, 2)

# 将 layout 添加到窗体
$form.Controls.Add($layout)

# ========== 辅助函数 ==========
function Add-LogEntry {
    param([string]$time, [string]$status, [string]$procName, [string]$procId, [string]$title)

    $item = New-Object System.Windows.Forms.ListViewItem($time)
    $item.SubItems.Add($status) | Out-Null
    $item.SubItems.Add($procName) | Out-Null
    $item.SubItems.Add($procId) | Out-Null
    $item.SubItems.Add($title) | Out-Null

    # 颜色标识
    if ($status -eq "LOCKED") {
        $item.BackColor = [System.Drawing.Color]::MistyRose
        $item.ForeColor = [System.Drawing.Color]::DarkRed
    } elseif ($status -eq "FREE") {
        $item.BackColor = [System.Drawing.Color]::Honeydew
        $item.ForeColor = [System.Drawing.Color]::DarkGreen
    } elseif ($status -eq "RESTART") {
        $item.BackColor = [System.Drawing.Color]::LightCyan
        $item.ForeColor = [System.Drawing.Color]::DarkBlue
    } elseif ($status -eq "KILLED") {
        $item.BackColor = [System.Drawing.Color]::LightSalmon
        $item.ForeColor = [System.Drawing.Color]::DarkRed
    } else {
        $item.BackColor = [System.Drawing.Color]::White
        $item.ForeColor = [System.Drawing.Color]::Black
    }

    # 保留最近的 200 条记录，防止内存膨胀
    if ($listView.Items.Count -ge 200) {
        $listView.Items.RemoveAt(0)
    }

    $listView.Items.Add($item) | Out-Null
    $item.EnsureVisible()
}

function Restart-ProcessByPid {
    param([int]$targetPid, [string]$procName)

    try {
        $proc = Get-Process -Id $targetPid -ErrorAction Stop
        $procPath = $proc.Path  # 获取进程可执行文件完整路径

        # 先 kill
        Write-Step ("正在终止进程: " + $procName + " (PID=" + $targetPid + ")") "Red"
        $proc.Kill()
        $proc.WaitForExit(5000)

        Start-Sleep -Seconds 1

        # 如果有路径，重新启动
        if ($procPath -and $procPath -ne "") {
            Write-Step ("正在重启进程: " + $procPath) "Yellow"
            try {
                Start-Process -FilePath $procPath -WindowStyle Normal
                Write-Step ("进程已重启: " + $procName) "Green"

                # 添加重启记录到列表
                $t = Get-Date -Format "HH:mm:ss"
                Add-LogEntry $t "RESTART" $procName $targetPid ("已重启: " + $procPath)
                return $true
            } catch {
                Write-Step ("重启失败: " + $_.Exception.Message) "Red"
                $t = Get-Date -Format "HH:mm:ss"
                Add-LogEntry $t "ERROR" $procName $targetPid ("重启失败: " + $_.Exception.Message)
                return $false
            }
        } else {
            Write-Step ("无法获取进程路径，仅终止了进程: " + $procName) "Yellow"
            $t = Get-Date -Format "HH:mm:ss"
            Add-LogEntry $t "WARN" $procName $targetPid "仅 kill (无路径信息，无法重启)"
            return $false
        }
    } catch {
        Write-Step ("操作失败: " + $_.Exception.Message) "Red"
        $t = Get-Date -Format "HH:mm:ss"
        Add-LogEntry $t "ERROR" $procName $targetPid ("操作失败: " + $_.Exception.Message)
        return $false
    }
}

function Write-Step {
    param([string]$msg, [string]$color = "White")
    $t = Get-Date -Format "HH:mm:ss"
    Write-Host ("[$t] $msg") -ForegroundColor $color
}

# ========== 检测函数（定时器和手动调用共用）==========
function Invoke-ClipboardCheck {
    $t = Get-Date -Format "HH:mm:ss"
    $info = [ClipUtil]::Detect()
    $isFree = ($info -eq "FREE")

    if ($isFree) {
        # 空闲状态
        if ($script:lastStatus -ne "FREE") {
            # 从占用变为空闲
            Add-LogEntry $t "FREE" "-" "-" "剪贴板已释放"
            $statusLabel.Text = "剪贴板空闲"
            $statusLabel.ForeColor = [System.Drawing.Color]::Green
        }
        $script:prevBlockedPid = $null
        $script:lastStatus = "FREE"
    } else {
        # 占用状态
        if ($info -match 'PID=(\d+)') {
            $procId = $matches[1]
            $titleMatch = $info -match "Title='(.*)'"
            $windowTitle = if ($titleMatch) { $matches[1] } else { "未知" }

            try {
                $p = Get-Process -Id $procId -ErrorAction Stop
                $procName = $p.ProcessName

                # 只在首次检测到该 PID 占用时添加记录（避免重复刷屏）
                if ($script:prevBlockedPid -ne $procId) {
                    Add-LogEntry $t "LOCKED" $procName $procId $windowTitle
                    $statusLabel.Text = ("剪贴板被占用: " + $procName + " (PID=" + $procId + ")")
                    $statusLabel.ForeColor = [System.Drawing.Color]::Red
                    $script:prevBlockedPid = $procId
                }
            } catch {
                # 进程已不存在
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
}

# ========== 定时器：每 3 秒检测剪贴板 ==========
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Invoke-ClipboardCheck })

# ========== 右键菜单事件 ==========
$menuRestart.Add_Click({
    if ($listView.SelectedItems.Count -gt 0) {
        $item = $listView.SelectedItems[0]
        $status = $item.SubItems[1].Text
        $procName = $item.SubItems[2].Text
        $pidText = $item.SubItems[3].Text

        if ($status -ne "LOCKED") {
            [System.Windows.Forms.MessageBox]::Show("只有被占用 (LOCKED) 状态的进程才能重启。", "提示", "OK", "Information")
            return
        }

        if ($pidText -eq "-" -or $pidText -eq "") {
            [System.Windows.Forms.MessageBox]::Show("无效的 PID，无法操作。", "错误", "OK", "Warning")
            return
        }

        $result = [System.Windows.Forms.MessageBox]::Show(
            "确定要重启进程「" + $procName + "」(PID=" + $pidText + ") 吗？`n`n操作将终止该进程并重新启动它。",
            "确认重启",
            "YesNo",
            "Question"
        )

        if ($result -eq "Yes") {
            $success = Restart-ProcessByPid -targetPid ([int]$pidText) -procName $procName
            if ($success) {
                Invoke-ClipboardCheck
            }
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

        if ($status -ne "LOCKED") {
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
        $text += "窗口标题: " + $item.SubItems[4].Text

        [System.Windows.Forms.Clipboard]::SetText($text)
        [System.Windows.Forms.MessageBox]::Show("进程信息已复制到剪贴板。", "提示", "OK", "Information")
    }
})

# ========== 窗口关闭事件 ==========
$form.Add_FormClosing({
    param($sender, $e)
    $timer.Stop()
    $result = [System.Windows.Forms.MessageBox]::Show(
        "确认退出剪贴板监控工具？",
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
Write-Step "UU 剪贴板监控工具启动" "Cyan"
Write-Step "检测间隔: 3秒 | 右键列表项可重启/结束进程" "Cyan"

# 添加启动记录
$t = Get-Date -Format "HH:mm:ss"
Add-LogEntry $t "INFO" "监控工具" "-" "启动监控..."
$statusLabel.Text = "正在监控剪贴板..."
$statusLabel.ForeColor = [System.Drawing.Color]::RoyalBlue

$timer.Start()

# 启动时立即检测一次
Invoke-ClipboardCheck

# 运行窗体
[System.Windows.Forms.Application]::Run($form)

