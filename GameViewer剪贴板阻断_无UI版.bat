@echo off
title UU剪贴板监控 - 阻断GameViewer占用(OpenClipboard内存修补)
cd /d "%~dp0"

:: 检查管理员权限，自动提权
fltmc >nul 2>&1 || (
    powershell -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)

:: 启动 PowerShell 监控脚本
echo 正在启动剪贴板阻断监控...
echo 原理：修补 GameViewer 进程的 OpenClipboard 函数 -> return FALSE
echo 使其无法持有剪贴板锁，实现无感阻断
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_BlockGameViewerClipboard.ps1" -Monitor
pause
