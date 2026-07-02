@echo off
title UU剪贴板监控工具 - UI版 (正式版)
cd /d "%~dp0"
start "" powershell -ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File "%~dp0UI监控工具.ps1" -HideConsole
exit /b
