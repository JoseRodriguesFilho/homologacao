#requires -Version 5.1
$ErrorActionPreference = "Stop"

$PowerShell64 = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$working = $PSScriptRoot.Replace("'", "''")

Start-Process `
    -FilePath $PowerShell64 `
    -Verb RunAs `
    -ArgumentList "-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -Command `"Set-Location -LiteralPath '$working'`""
