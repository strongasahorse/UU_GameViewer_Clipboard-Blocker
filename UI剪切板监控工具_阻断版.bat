@echo off
cd /d "%~dp0"

:: 检测管理员权限
fltmc >nul 2>&1 || (
    :: 非管理员 -> 直接启动提升后的 PowerShell（隐藏，无第二个 cmd 窗口）
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -WindowStyle Hidden -FilePath powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0UI监控工具_阻断版.ps1\" -HideConsole'"
    exit /b
)

:: 已提权 -> 后台启动脚本，cmd 即刻退出
start "" /MIN powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%~dp0UI监控工具_阻断版.ps1" -HideConsole
exit
