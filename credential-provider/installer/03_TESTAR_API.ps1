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

$LogPath = Join-Path $PSScriptRoot "03_TESTAR_API.log"
try {
    Start-Transcript -Path $LogPath -Append -Force | Out-Null
}
catch {
    # Nao interrompe o script se o transcript nao puder ser iniciado.
}

$ConfigKey = "HKLM:\SOFTWARE\e-GOV\LabCPFProvider"

$config = Get-ItemProperty $ConfigKey -ErrorAction Stop

$baseUrl = $config.ApiBaseUrl
$token = $config.ApiToken

Write-Host ""
Write-Host "Teste API e-GOV" -ForegroundColor Cyan
Write-Host ""

$health = Invoke-RestMethod `
    -Method Get `
    -Uri "$baseUrl/health" `
    -TimeoutSec 5

Write-Host "Health:" -ForegroundColor Green
$health | ConvertTo-Json

$cpf = Read-Host "CPF para preview"
$target = Read-Host "Tipo [student/admin]"

if (-not $target) {
    $target = "student"
}

$body = @{
    cpf = $cpf
    computer = $env:COMPUTERNAME
    target = $target
} | ConvertTo-Json -Compress

$response = Invoke-RestMethod `
    -Method Post `
    -Uri "$baseUrl/auth/preview" `
    -Headers @{ "X-eGOV-Token" = $token } `
    -ContentType "application/json" `
    -Body $body `
    -TimeoutSec 5

Write-Host ""
Write-Host "Preview:" -ForegroundColor Green
$response | ConvertTo-Json

Read-Host "ENTER para fechar"
