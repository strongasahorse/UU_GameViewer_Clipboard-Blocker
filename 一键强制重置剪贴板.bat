@echo off
title UU远程剪贴板 - 一键强制重置
cd /d "%~dp0"
echo ============================================
echo  UU远程剪贴板 - 一键强制重置
echo  杀占用进程 + 重置剪贴板（无需确认）
echo ============================================
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0方案2_核心.ps1" -kill
if %errorlevel% equ 0 (
    echo.
    echo ============================================
    echo  [成功] 剪贴板已重置! 可以正常使用 Ctrl+V
    echo ============================================
) else (
    echo.
    echo ============================================
    echo  [失败] 操作未完全成功
    echo  请尝试关闭 UU远程 后重试
    echo ============================================
)
echo.
echo 5秒后自动关闭...
timeout /t 5 /nobreak >nul
