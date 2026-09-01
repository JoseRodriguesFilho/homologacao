@echo off
cd /d "%~dp0"
set "PS64=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS64%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0\00_ABRIR_POWERSHELL_ADMIN.ps1"
