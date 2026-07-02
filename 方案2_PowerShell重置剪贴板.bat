@echo off
title UU远程剪贴板恢夿- 方案2
cd /d "%~dp0"

:menu
cls
echo ============================================
echo   UU远程剪贴板恢夿- 方案2
echo   三重路径: 检浿-^> OLE重置 -^> 杀进程
echo ============================================
echo.
echo  1. 检测剪贴板占用进程
echo  2. 重置剪贴板(OLE路径)
echo  3. 强制重置 (杀占用进程 + 重置)
echo  4. 连续监控 (一直运行，自动恢复)
echo  5. 监控剪贴板状(按3-强制杀进程,按6-重启explorer)
echo  6. 重启 explorer.exe (终极核武)
echo  7. 退出
echo.
set /p choice="请选择 (1/2/3/4/5/6/7): "

if "%choice%"=="1" goto detect
if "%choice%"=="2" goto reset
if "%choice%"=="3" goto kill
if "%choice%"=="4" goto monitor
if "%choice%"=="5" goto watch
if "%choice%"=="6" goto resetsplorer
if "%choice%"=="7" exit /b
goto menu

:detect
cls
echo ============================================
echo  检测剪贴板占用
echo ============================================
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0方案2_核心.ps1" -detect
echo.
pause
goto menu

:reset
cls
echo ============================================
echo  重置剪贴板(OLE路径)
echo  需要无人占用剪贴板才能成功
echo ============================================
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0方案2_核心.ps1" -reset
echo.
if %errorlevel% equ 0 (
    echo 现在试试 Ctrl+V 粘贴
) else (
    echo.
    echo [失败] UU远程占用了剪贴板
    echo 请先逿[3] 强制重置
)
echo.
pause
goto menu

:kill
cls
echo ============================================
echo  强制重置剪贴板echo  将杀死占用剪贴板的进稿
echo ============================================
echo.
echo  警告: 如果 UU远程 正在运行，远程连接将断开!
echo.
set /p confirm="确认继续? (Y/N): "

if /i not "%confirm%"=="Y" goto menu

echo.
powershell -ExecutionPolicy Bypass -File "%~dp0方案2_核心.ps1" -kill

if %errorlevel% equ 0 (
    echo.
    echo [成功] 剪贴板已重置! 可以正常使用?) else (
    echo.
    echo [失败] 操作未完房)
echo.
pause
goto menu

:monitor
cls
echo ============================================
echo  连续监控模式
echo  毿0秒检测一次，无人占用时自动重罿echo  关闭窗口房Ctrl+C 停止
echo ============================================
echo.
start "UU远程剪贴板监掿- 请勿关闭此窗叿 /MIN powershell -ExecutionPolicy Bypass -File "%~dp0方案2_核心.ps1" -monitor
echo  监控已启势(最小化窗口)
echo.
pause
goto menu

:watch
cls
echo ============================================
echo  监控剪贴板状怿不自动重罿
echo  挿3 = 强制重置(杀进程) , 挿6 = 重启explorer
echo  毿0秒刷新一次，Ctrl+C 停止
echo ============================================
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0方案2_核心.ps1" -watch
echo.
pause
goto menu

:resetsplorer
cls
echo ============================================
echo  重启 explorer.exe (终极核武)
echo  将重启桌面和任务栿echo ============================================
echo.
echo  警告: 桌面和任务栏会短暂消失然后恢夿
echo.
set /p confirm="确认继续? (Y/N): "

if /i not "%confirm%"=="Y" goto menu

echo.
powershell -ExecutionPolicy Bypass -File "%~dp0方案2_核心.ps1" -resetexplorer

if %errorlevel% equ 0 (
    echo.
    echo [成功] Explorer 已重吿) else (
    echo.
    echo [失败] 重启失败
)
echo.
pause
goto menu
