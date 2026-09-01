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

$LogPath = Join-Path $PSScriptRoot "06_DESINSTALAR.log"
try {
    Start-Transcript -Path $LogPath -Append -Force | Out-Null
}
catch {
    # Nao interrompe o script se o transcript nao puder ser iniciado.
}

$Guid = "{D2D9E531-8DB1-4C83-ABF9-810F70A1EB09}"
$Providers = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"
$Clsid = "Registry::HKEY_CLASSES_ROOT\CLSID"
$ExcludeKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$DefaultKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
$ConfigKey = "HKLM:\SOFTWARE\e-GOV\LabCPFProvider"
$UserTile = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\UserTile"

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

Remove-ItemProperty $ExcludeKey -Name ExcludedCredentialProviders -Force -ErrorAction SilentlyContinue
Remove-ItemProperty $DefaultKey -Name DefaultCredentialProvider -Force -ErrorAction SilentlyContinue

Stop-Service -Name "eGOVLabCPFAgent" -Force -ErrorAction SilentlyContinue
& sc.exe delete "eGOVLabCPFAgent" | Out-Null

Remove-Item "$Providers\$Guid" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$Clsid\$Guid" -Recurse -Force -ErrorAction SilentlyContinue

if (Test-Path $UserTile) {
    Get-ChildItem $UserTile | ForEach-Object {
        try {
            if ([string]$_.GetValue("") -ieq $Guid) {
                Remove-Item $_.PSPath -Recurse -Force
            }
        }
        catch {}
    }
}

Remove-Item "$env:WINDIR\System32\LabCPFProvider.dll" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ProgramFiles\e-GOV\LabCPF" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $ConfigKey -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "e-GOV Login removido." -ForegroundColor Green
Write-Host "As contas Aluno e-GOV e Admin e-GOV foram preservadas." -ForegroundColor Yellow
Write-Host "Reinicie o Windows." -ForegroundColor Cyan
Read-Host "ENTER para fechar"
