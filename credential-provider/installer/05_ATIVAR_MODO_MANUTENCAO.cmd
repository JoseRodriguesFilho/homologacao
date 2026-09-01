@echo off
cd /d "%~dp0"

set "PS64=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" (
    set "PS64=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
)

"%PS64%" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0\05_ATIVAR_MODO_MANUTENCAO.ps1"
