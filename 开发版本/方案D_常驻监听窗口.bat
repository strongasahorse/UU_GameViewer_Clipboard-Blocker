
chcp 65001 >nul
@echo off
title UU远程剪贴板恢复 - 方案D (常驻监听窗口)
cd /d "%~dp0"

:menu
cls
echo ============================================
echo   UU远程剪贴板恢复 - 方案D v2
echo   常驻监听窗口 + 多层恢复
echo ============================================
echo.
echo  触发方式:
echo    [事件] AddClipboardFormatListener
echo    [链]   SetClipboardViewer
echo    [定时] 30秒兜底
echo.
echo  恢复层级:
echo    L0: 快速OLE重置
echo    L1: STA消息泵OLE
echo    L2: Win32重试 (50次)
echo    L3: WM_CLOSE关闭占用窗口
echo    L4: 强制终止占用进程
echo    L5: 重启 explorer.exe
echo.
echo  1. 启动监听 (显示日志窗口)
echo  2. 启动监听 (最小化后台)
echo  3. 退出
echo.
set /p choice="请选择 (1/2/3): "

if "%choice%"=="1" goto show
if "%choice%"=="2" goto hide
if "%choice%"=="3" exit /b
goto menu

:show
cls
echo ============================================
echo  启动常驻监听窗口
echo  关闭此窗口即停止监听
echo ============================================
echo.
echo  ! 此窗口保持打开，监听才有效 !
echo  窗口内有详细日志，可观察恢复过程
echo.
pause
start "UU Clipboard Monitor - DO NOT CLOSE" powershell -ExecutionPolicy Bypass -NoExit -Command "& '%~dp0方案D_常驻监听窗口.ps1'"
goto menu

:hide
cls
echo ============================================
echo  启动常驻监听 (最小化后台)
echo ============================================
echo.
start "UU Clipboard Monitor - DO NOT CLOSE" /MIN powershell -ExecutionPolicy Bypass -NoExit -Command "& '%~dp0方案D_常驻监听窗口.ps1' -silent"
echo  监听已启动 (最小化窗口)
echo  关闭窗口或结束 powershell 进程即可停止
echo.
pause
goto menu
