@echo off
title UU剪贴板监控工具 - UI版
cd /d "%~dp0"

echo ============================================
echo   UU剪贴板监控工具 - UI版
echo   图形界面，实时监控，右键重启进程
echo ============================================
echo.
echo  启动 GUI 监控界面...
echo  提示: 如需隐藏后台黑色窗口，请使用 方案3_UI监控工具_正式版.bat
echo.
start "" powershell -ExecutionPolicy Bypass -WindowStyle Normal -File "%~dp0UI监控工具.ps1"
exit /b
