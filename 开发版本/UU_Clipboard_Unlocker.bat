@echo off
title UU Clipboard Unlocker
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0UU_Clipboard_Unlocker.ps1"
pause
