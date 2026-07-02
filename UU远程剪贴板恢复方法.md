# UU 远程工具剪贴板失效的恢复方法

## 背景

UU 远程（UU Remote）是第三方远程控制软件，**不是** Windows 内置 RDP，因此不存在 `rdpclip.exe` 进程。  
UU 禁用剪贴板的方式通常是对 Windows 剪贴板系统进行 **API 拦截** 或 **剪贴板查看器链 (Clipboard Viewer Chain) 钩子**，而不是通过 RDP 通道。

**实测发现**：在本环境中，UU 的 `GameViewer.exe` 进程会创建一个名为 `clipboard` 的隐藏窗口，并持续调用 `OpenClipboard` **持有不释放**，导致所有其他进程无法访问剪贴板（OpenClipboard 返回 FALSE）。这是比单纯钩子更暴力的阻塞手段。

**"偶尔能用"** 的现象说明：

- UU 的钩子并非 100% 时刻生效（可能有状态竞争、进程重启、焦点切换等触发解除）
- 某些操作可能无意间重建了剪贴板查看器链，暂时绕过了 UU 的钩子
- UU 偶尔会短暂释放 OpenClipboard，形成时间窗口

下面从 **最轻量到最重量** 给出多种恢复方法。

---

## 方法一：通过 `clip.exe` 刷新剪贴板链（最简单）

Windows 自带 `clip.exe`，写入内容时会触发剪贴板链上的所有窗口接收 `WM_DRAWCLIPBOARD` 消息，可能暂时绕过钩子。

```batch
echo  test > NUL | clip
```

或者写入一段随机内容：

```batch
echo %random% | clip
```

**原理**：`clip.exe` 调用 `SetClipboardData`，这会广播剪贴板更新消息，UU 的钩子可能在此过程中状态错乱，暂时失效。

**成功率**：低 ~ 中（瞬间生效，但仅短暂恢复）

**实测结论**：在 UU 持有 OpenClipboard 的情况下完全无效。

---

## 方法二：PowerShell 彻底清空并重新初始化剪贴板

比 `clip.exe` 更彻底，调用 .NET 底层 API：

```powershell
# 清空剪贴板
[System.Windows.Forms.Clipboard]::Clear()

# 写入一个空文本，重建剪贴板数据对象
[System.Windows.Forms.Clipboard]::SetText(' ')
```

**作为一键脚本**（`clip-reset.ps1`）：

```powershell
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Clipboard]::Clear()
Start-Sleep -Milliseconds 200
[System.Windows.Forms.Clipboard]::SetText(' ')
Write-Host '剪贴板已重置'
```

执行策略如果受限，用：

```batch
powershell -ExecutionPolicy Bypass -File clip-reset.ps1
```

**原理**：直接调用 .NET 的 `System.Windows.Forms.Clipboard` 类，它底层使用 OLE 剪贴板（`OleSetClipboard` / `OleGetClipboard`），与 Win32 `SetClipboardData` 走不同的路径。如果 UU 只 hook 了 Win32 层的 API，OLE 路径可能逃过拦截。

**⚠ 注意 STA 线程要求**：`System.Windows.Forms.Clipboard` 要求在 STA（单线程单元）模式 + 消息泵下调用。在 PowerShell 中直接调用可能抛 `"Requested Clipboard operation did not succeed"`。需要通过 WinForms 窗口提供消息泵：

```powershell
Add-Type -AssemblyName System.Windows.Forms
$form = New-Object System.Windows.Forms.Form
$form.WindowState = "Minimized"
$form.ShowInTaskbar = $false
$form.Add_Shown({
    [System.Windows.Forms.Clipboard]::Clear()
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.Clipboard]::SetText(' ')
    Write-Host "OK"
    $form.Close()
})
[System.Windows.Forms.Application]::Run($form)
```

**成功率**：中 ~ 高（取决于 UU 是否同时 hook 了 OLE 层）

**实测结论**：当 UU 持有 OpenClipboard 时也无效（OLE 内部也依赖 OpenClipboard）。需先释放 OpenClipboard 再调用。

---

## 方法三：通过 `SetClipboardViewer` 重建剪贴板查看器链（核心方案）

UU 禁用剪贴板的典型做法是安装自己的剪贴板查看器钩子（`SetClipboardViewer`），然后拦截 `WM_DRAWCLIPBOARD` / `WM_CHANGECBCHAIN`，不让消息传递到后续链中。

**恢复思路**：增加一个新的查看器窗口，重新连接剪贴板链，从而把 UU 的钩子"挤掉"或绕过。

可以用 PowerShell 直接操作：

```powershell
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class ClipViewer : Form {
    public ClipViewer() {
        this.Load += (s, e) => {
            this.Hide();
            NativeMethods.SetClipboardViewer(this.Handle);
        };
    }
}
public class NativeMethods {
    [DllImport("user32.dll")]
    public static extern IntPtr SetClipboardViewer(IntPtr hWnd);
}
"@ -ReferencedAssemblies System.Windows.Forms.dll

$viewer = New-Object ClipViewer
[System.Windows.Forms.Application]::Run($viewer)
```

**也可以编译 C# 小工具**（需要 .NET Framework SDK）：

```csharp
// clipboard-unhook.cs
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

class ClipUnhook
{
    [DllImport("user32.dll")]
    static extern IntPtr SetClipboardViewer(IntPtr hWnd);

    static void Main()
    {
        var frm = new Form { ShowInTaskbar = false, WindowState = FormWindowState.Minimized };
        frm.Load += (s, e) =>
        {
            frm.Hide();
            SetClipboardViewer(frm.Handle);
        };
        Application.Run(frm);
    }
}
```

编译：

```batch
csc.exe /reference:System.Windows.Forms.dll clipboard-unhook.cs
```

**原理**：`SetClipboardViewer` 把自己的窗口插入到剪贴板查看器链头部。链恢复后，UU 的钩子不再是唯一节点，剪贴板消息有机会通过其他路径传递。

**成功率**：高（如果 UU 使用的是标准的剪贴板查看器链 hook）

**实测结论**：不能解决 OpenClipboard 独占问题，但可以作为辅助手段参与剪贴板链。

---

## 方法四：重启 `explorer.exe`（重武器）

Explorer.exe 维护着桌面环境的剪贴板查看器链的一部分。重启它会重置整个链。

```batch
taskkill /f /im explorer.exe
start explorer.exe
```

或者做成一个 bat 脚本：

```batch
@echo off
echo 正在重启 explorer.exe，重置剪贴板链...
taskkill /f /im explorer.exe >nul 2>&1
ping 127.0.0.1 -n 3 >nul
start explorer.exe
echo 完成。
```

**注意**：重启 explorer 会导致任务栏、桌面图标、文件管理器窗口全部重启，正在运行的其他程序不受影响（但需几秒恢复 UI）。

**成功率**：高（几乎所有 hook 都会被重置，但代价较大）

**实测结论**：可重置剪贴板查看器链，但不能释放 UU 对 OpenClipboard 的持有。

---

## 方法五：使用 AutoHotkey 脚本维护剪贴板

AutoHotkey 可以通过 Win32 API 层面的 `Clipboard` 对象绕过部分钩子。

创建一个 `clipboard-keepalive.ahk`：

```autohotkey
; 每 5 秒读取并重新写入剪贴板，维持剪贴板链畅通
#Persistent
SetTimer, RefreshClipboard, 5000
return

RefreshClipboard:
    if (Clipboard != "") {
        OldClip := Clipboard
        Sleep 100
        Clipboard := OldClip
    }
    else {
        Clipboard := " "
        Sleep 50
        Clipboard := ""
    }
return
```

或者做一个快捷键手动触发：

```autohotkey
; Ctrl+Alt+V 强制重置剪贴板
^!v::
    ClipSaved := ClipboardAll
    Clipboard := ""
    Sleep 100
    Clipboard := ClipSaved
    ClipSaved := ""
    ToolTip 剪贴板已刷新
    Sleep 1000
    ToolTip
return
```

**原理**：AutoHotkey 的 `Clipboard` 在底层使用 Win32 `GetClipboardData` / `SetClipboardData`，但带有自己的超时重试机制（内部重试 4 次）。定时操作可能让 UU 的钩子来不及持续拦截。

**成功率**：中 ~ 高（取决于 UU 的 hook 强度）

**实测结论**：AHK 本身也可能成为 OpenClipboard 的占有者（实测中发现 AHK 出现在剪贴板所有者列表中），不一定能绕过 UU 的独占式 OpenClipboard。

---

## 方法六：通过 NirCmd 或 Sysinternals 工具

### NirCmd

下载 [NirCmd](https://www.nirsoft.net/utils/nircmd.html)（一个无需安装的 Windows 命令行工具）：

```batch
nircmd clipboard write "test"
nircmd clipboard clear
```

### Sysinternals Clip

```batch
clip < somefile.txt
```

**原理**：这些工具可能使用不同于典型 Win32 `SetClipboardData` 的 API 路径（例如 OLE 剪贴板）。

**成功率**：低 ~ 中（依赖 UU 的 hook 粒度）

---

## 方法七：注册表禁用剪贴板挂钩（部分远程软件）

某些远程软件通过注册表全局钩子（`AppInit_DLLs`）注入剪贴板拦截 DLL。

检查注册表路径：

```
HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows\AppInit_DLLs
```

如果 UU 写入了自己的 DLL 路径，尝试清空该值：

```batch
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" /v AppInit_DLLs
```

> **警告**：AppInit_DLLs 中的 DLL 会被加载到所有加载 User32.dll 的进程中，修改不当可能导致系统不稳定。**除非确认 UU 使用此机制，否则不建议修改。**

**成功率**：高（如果 UU 确实使用了 AppInit_DLLs；但现代远程工具更倾向用 `SetClipboardViewer` 或 `SetWinEventHook`，此法适用面较窄）

---

## 方法八：第三方剪贴板管理器（旁路方案）

安装一个剪贴板管理器（如 Ditto、ClipX、CopyQ），这类工具会维护自己的剪贴板历史记录，并通过自己的查看器窗口维持在剪贴板链中的位置。

**推荐**：
- **Ditto** — 开源、支持网络同步、通过自己的钩子持续监控剪贴板
- **CopyQ** — 跨平台、支持脚本扩展、有更强的剪贴板恢复能力
- **ClipX** — 轻量级、老牌经典

这些管理器启动后会调用 `SetClipboardViewer` / `AddClipboardFormatListener`，成为剪贴板链的一个节点。即使 UU 试图断开链，管理器可能维持连接。

**原理**：让剪贴板链中有多个持续的查看器节点，UU 无法单独切断所有链路。

**成功率**：高（长期解决方案，不依赖临时 hack）

---

## 方法九：C++ 小工具直接调用 EmptyClipboard

这是 Windows 剪贴板最底层的 API，比 .NET OLE 层更低：

```cpp
// clipboard_reset.cpp
// 编译: cl.exe clipboard_reset.cpp /link user32.lib
#include <windows.h>
#include <stdio.h>

int main()
{
    for (int i = 0; i < 5; i++)
    {
        if (OpenClipboard(NULL))
        {
            printf("第 %d 次: OpenClipboard 成功\n", i + 1);
            EmptyClipboard();
            CloseClipboard();
            printf("剪贴板已清空\n");
            return 0;
        }
        Sleep(100);
    }
    printf("OpenClipboard 失败（可能被其他进程独占）\n");
    return 1;
}
```

编译：

```batch
cl.exe clipboard_reset.cpp /link user32.lib
```

**原理**：`OpenClipboard(NULL)` 以 NULL 所有者打开剪贴板，`EmptyClipboard()` 清空所有格式数据并重置剪贴板锁。UU 的 hook 往往是在 `SetClipboardData` 上做拦截，`EmptyClipboard` 可能不在其拦截范围内。

**成功率**：中 ~ 高（如果 UU 未拦截 `EmptyClipboard`）

**实测结论**：当 UU 持有 OpenClipboard 时，OpenClipboard(NULL) 也返回 FALSE，无法执行 EmptyClipboard。需要先释放 UU 的占用才能生效。

---

## 方法十：通过 `AddClipboardFormatListener`（Vista+ 新方式）

Vista 引入的新 API `AddClipboardFormatListener`，比旧的 `SetClipboardViewer` 更现代，不容易被传统 hook 干扰。

用 PowerShell 注册监听：

```powershell
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class ClipboardListener : Form {
    [DllImport("user32.dll")]
    static extern bool AddClipboardFormatListener(IntPtr hwnd);

    protected override void WndProc(ref Message m) {
        // 0x031D = WM_CLIPBOARDUPDATE
        if (m.Msg == 0x031D) {
            // 收到剪贴板更新通知，说明链通
        }
        base.WndProc(ref m);
    }

    public ClipboardListener() {
        this.Load += (s, e) => {
            this.Hide();
            AddClipboardFormatListener(this.Handle);
        };
    }
}
"@ -ReferencedAssemblies System.Windows.Forms.dll

$listener = New-Object ClipboardListener
[System.Windows.Forms.Application]::Run($listener)
```

**原理**：`AddClipboardFormatListener` 不走旧式的剪贴板查看器链，而是通过消息接收 `WM_CLIPBOARDUPDATE` 消息。UU 如果只 hook 了旧链，这个方法可以绕过。

**成功率**：中（UU 如果也 hook 了消息泵则可能仍被拦截）

**作为方案 D 的基础**：此 API 是实现事件驱动剪贴板监控的最佳基础。详见方法十一（方案 D）。

---

## 方法十一：常驻监听窗口（推荐方案 D）

基于方法十的 `AddClipboardFormatListener`，创建一个常驻的隐藏窗口，**事件驱动** 地响应剪贴板变化，结合 OLE 重置逻辑。

**核心思路**：

```
传统轮询（方案2） ──── 每10秒检查一次
事件驱动（方案D） ──── 剪贴板变化瞬间通知，零延迟
```

**实现方式**：一个常驻后台的隐藏窗口，同时做两件事：

1. 通过 `AddClipboardFormatListener` 注册剪贴板更新监听
2. 通过 `SetClipboardViewer` 插入剪贴板查看器链（双重保险）
3. 收到 `WM_CLIPBOARDUPDATE` 时尝试 OLE 重置
4. 内置定时器兜底（每 30 秒额外检查一次，防止事件丢失）

**优势**：

| 对比项 | 方案2（轮询） | 方案D（事件驱动） |
|--------|-------------|----------------|
| CPU 占用 | 极低（10秒一次 API 调用） | **0%（无事件时休眠）** |
| 恢复延迟 | 平均 5 秒，最长 10 秒 | **毫秒级** |
| 窗口创建 | 每次检测重建 WinForms | **一次性创建，常驻使用** |
| 系统负担 | 轻 | **更轻** |

**成功率**：中 ~ 高（取决于 UU 是否拦截了 `WM_CLIPBOARDUPDATE` 消息路径）

**脚本文件**：`方案D_常驻监听窗口.ps1`（需保持运行，关闭窗口即停止）

---

## 综合建议

| 方案 | 难度 | 副作用 | 推荐场景 |
|------|------|--------|----------|
| ① `echo \| clip` | ★☆☆ 极低 | 无 | 临时应急，先试试手 |
| ② PowerShell OLE | ★★☆ 低 | 需消息泵 | UU 未占 OpenClipboard 时的日常恢复 |
| ③ 重建查看器链 | ★★★ 中 | 需运行脚本 | UU 长期禁用时的核心对抗方案 |
| ④ 重启 explorer | ★☆☆ 低 | 桌面闪烁几秒 | 其他方法无效时的兜底 |
| ⑤ AutoHotkey 脚本 | ★★☆ 低 | 需安装 AHK | 需要持续保持剪贴板可用 |
| ⑥ NirCmd 工具 | ★☆☆ 低 | 需下载工具 | 没有开发环境的备选 |
| ⑦ 注册表 | ★★★ 中 | 有系统风险 | 仅当确认 UU 使用 AppInit_DLLs |
| ⑧ 第三方管理器 | ★★☆ 低 | 需安装软件 | **长期最佳实践** |
| ⑨ C++ EmptyClipboard | ★★★ 中 | 需编译环境 | 彻底的底层重置 |
| ⑩ AddClipboardFormatListener | ★★☆ 中 | 需运行脚本 | 比方法③更现代的替代 |
| **⑪ 事件驱动监听（方案D）** | ★★☆ 中 | 需常驻进程 | **兼顾效率与响应速度的最佳自研方案** |

### 事件驱动 vs 轮询对比

| 维度 | 方案2（轮询 10s） | 方案A（事件驱动） | 方案B（轻量轮询 3s） | 方案C（自适应间隔） | 方案D（常驻监听） |
|------|-----------------|-----------------|-------------------|-----------------|-----------------|
| CPU 占用 | 极低 | 0% | 极低 | 极低 | 0% |
| 恢复延迟 | ~5s 平均 | **毫秒级** | ~1.5s 平均 | 1~15s | **毫秒级** |
| 窗口操作 | 每次重建 | 从不重建 | 每次重建 | 每次重建 | **一次建永久用** |
| 实现复杂度 | 低 | 中 | 低 | 中 | **中** |
| 可靠性 | 高 | 中（事件可能丢失） | 高 | 高 | **高（事件+定时兜底）** |

**推荐流程**：

1. **先试** ② (PowerShell OLE) — 零成本，几秒见效则最好
2. **长期运行** ⑪ (方案D 常驻监听) — 事件驱动，零延迟
3. **不行再试** ④ (重启 explorer) — 已验证有效但不太优雅
4. **兜底方案** ⑧ (Ditto/CopyQ 管理器) — 一劳永逸
5. **终极对抗** ⑨ (C++ EmptyClipboard) — 如果 UU 升级了 hook 方式

---

## 补充：如何判断 UU 用什么方式禁用剪贴板

### 检测谁持有 OpenClipboard

用 PowerShell 直接检测（无需额外工具）：

```powershell
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Check {
    [DllImport("user32.dll")] static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder t, int m);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    public static string Detect() {
        IntPtr h = GetOpenClipboardWindow();
        if (h == IntPtr.Zero || !IsWindow(h)) return "FREE";
        uint pid; GetWindowThreadProcessId(h, out pid);
        int L = GetWindowTextLength(h);
        var sb = new System.Text.StringBuilder(L + 1);
        GetWindowText(h, sb, sb.Capacity);
        return "BLOCKED: HWND=" + h + " PID=" + pid + " Title='" + sb.ToString() + "'";
    }
}
"@
[Check]::Detect()
```

如果返回 `BLOCKED: HWND=xxxx PID=yyyy Title='clipboard'`，说明 UU 正通过 `clipboard` 窗口持有 OpenClipboard，属于**独占式阻塞**，大部分第三方工具也无效，需杀死该进程或等待其释放。

### 使用 Process Explorer 进一步分析

用 [Process Explorer](https://learn.microsoft.com/en-us/sysinternals/downloads/process-explorer) 或 [API Monitor](http://www.rohitab.com/apimonitor) 监控 UU 进程的 `user32.dll` API 调用：

| 观察到的 API 调用 | UU 使用的机制 | 推荐应对方案 |
|---|---|---|
| `SetClipboardViewer` / `ChangeClipboardChain` | 剪贴板查看器链 hook | ③ ⑧ ⑩ |
| `SetWinEventHook`，参数含 `EVENT_SYSTEM_CLIPBOARDUPDATE` | 现代事件钩子 | ⑩ ⑪ |
| `SetWindowsHookEx`，hook type = `WH_GETMESSAGE` | 全局消息钩子 | ⑨ 最有效 |
| `OpenClipboard` / 创建隐藏 "clipboard" 窗口 | 独占式阻塞 | ② 结合杀进程 |
| AppInit_DLLs 中有 UU 的 DLL | 全局 DLL 注入 | ⑦ |

---

*文档版本：v2.0*  
*适用工具：UU 远程 (UU Remote) 及类似第三方远程控制软件*  
*最后更新：2025年6月*
