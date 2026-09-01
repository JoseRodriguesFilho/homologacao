#requires -Version 5.1
# e-GOV Login requires 64-bit Windows PowerShell on x64 Windows.
# Microsoft.PowerShell.LocalAccounts is not exposed to 32-bit PowerShell.
if ([Environment]::Is64BitOperatingSystem -and [IntPtr]::Size -eq 4) {
    $PowerShell64 = Join-Path $env:WINDIR "Sysnative\WindowsPowerShell\v1.0\powershell.exe"

    if (-not (Test-Path $PowerShell64)) {
        throw "PowerShell 64-bit nao encontrado em $PowerShell64"
    }

    $p = Start-Process `
        -FilePath $PowerShell64 `
        -ArgumentList @(
            "-NoProfile",
            "-NoExit",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`""
        ) `
        -Wait `
        -PassThru

    exit $p.ExitCode
}

$ErrorActionPreference = "Stop"

$LogPath = Join-Path $PSScriptRoot "05_ATIVAR_MODO_MANUTENCAO.log"
try {
    Start-Transcript -Path $LogPath -Append -Force | Out-Null
}
catch {
    # Nao interrompe o script se o transcript nao puder ser iniciado.
}

$ExcludeKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$DefaultKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"

function Ensure-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $PowerShell64 = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
        Start-Process $PowerShell64 -Verb RunAs -ArgumentList "-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    }
}

Ensure-Admin

Remove-ItemProperty `
    $ExcludeKey `
    -Name ExcludedCredentialProviders `
    -Force `
    -ErrorAction SilentlyContinue

Remove-ItemProperty `
    $DefaultKey `
    -Name DefaultCredentialProvider `
    -Force `
    -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "MODO MANUTENCAO ATIVO." -ForegroundColor Green
Write-Host "Senha/PIN/providers nativos foram liberados." -ForegroundColor Cyan
Write-Host "Reinicie ou faca logoff." -ForegroundColor Cyan
Read-Host "ENTER para fechar"
