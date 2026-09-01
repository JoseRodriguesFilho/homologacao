#requires -Version 5.1
$ErrorActionPreference = "Stop"

if ([Environment]::Is64BitOperatingSystem -and [IntPtr]::Size -eq 4) {
    $PS64 = Join-Path $env:WINDIR "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    & $PS64 -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$Guid = "{D2D9E531-8DB1-4C83-ABF9-810F70A1EB09}"
$ConfigPath = "SOFTWARE\e-GOV\LabCPFProvider"

function Result([string]$Name, [bool]$Ok, [string]$Detail = "") {
    $mark = if ($Ok) { "OK" } else { "ERRO" }
    $color = if ($Ok) { "Green" } else { "Red" }
    Write-Host ("{0,-28} {1,-5} {2}" -f $Name, $mark, $Detail) -ForegroundColor $color
}

Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop

$student = Get-LocalUser -Name "AlunoEGOV" -ErrorAction SilentlyContinue
$admin = Get-LocalUser -Name "AdminEGOV" -ErrorAction SilentlyContinue

Result "Conta Aluno e-GOV" ($null -ne $student)
Result "Conta Admin e-GOV" ($null -ne $admin)

$users = Get-LocalGroup -SID "S-1-5-32-545" -ErrorAction Stop
$admins = Get-LocalGroup -SID "S-1-5-32-544" -ErrorAction Stop

$studentInUsers = $false
$studentInAdmins = $false
$adminInAdmins = $false

if ($student) {
    $studentInUsers = $null -ne (
        Get-LocalGroupMember -Group $users.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.SID -eq $student.SID }
    )

    $studentInAdmins = $null -ne (
        Get-LocalGroupMember -Group $admins.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.SID -eq $student.SID }
    )
}

if ($admin) {
    $adminInAdmins = $null -ne (
        Get-LocalGroupMember -Group $admins.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.SID -eq $admin.SID }
    )
}

Result "Aluno em Usuarios" $studentInUsers
Result "Aluno fora Administradores" (-not $studentInAdmins)
Result "Admin em Administradores" $adminInAdmins

$dll = "$env:WINDIR\System32\LabCPFProvider.dll"
Result "Credential Provider DLL" (Test-Path $dll) $dll

$providerPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$Guid"
Result "Provider registrado" (Test-Path $providerPath)

$service = Get-Service -Name "eGOVLabCPFAgent" -ErrorAction SilentlyContinue
Result "Agent instalado" ($null -ne $service)
Result "Agent em execucao" ($null -ne $service -and $service.Status -eq "Running") $(if($service) {$service.Status} else {""})

$base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::LocalMachine,
    [Microsoft.Win32.RegistryView]::Registry64
)

try {
    $key = $base.OpenSubKey($ConfigPath, $false)

    Result "Chave Registry64" ($null -ne $key)

    if ($key) {
        $studentSecretOk = $false
        $adminSecretOk = $false

        try {
            $studentSecretOk =
                $key.GetValueKind("StudentSecret") -eq [Microsoft.Win32.RegistryValueKind]::Binary -and
                ([byte[]]$key.GetValue("StudentSecret")).Length -gt 0
        } catch {}

        try {
            $adminSecretOk =
                $key.GetValueKind("AdminSecret") -eq [Microsoft.Win32.RegistryValueKind]::Binary -and
                ([byte[]]$key.GetValue("AdminSecret")).Length -gt 0
        } catch {}

        Result "StudentSecret REG_BINARY" $studentSecretOk
        Result "AdminSecret REG_BINARY" $adminSecretOk

        $apiBase = [string]$key.GetValue("ApiBaseUrl", "")
        $apiToken = [string]$key.GetValue("ApiToken", "")

        Result "ApiBaseUrl configurada" (-not [string]::IsNullOrWhiteSpace($apiBase)) $apiBase
        Result "ApiToken configurado" (-not [string]::IsNullOrWhiteSpace($apiToken))

        if (-not [string]::IsNullOrWhiteSpace($apiBase)) {
            try {
                $health = Invoke-RestMethod -Method Get -Uri "$($apiBase.TrimEnd('/'))/health" -TimeoutSec 5
                Result "API /health" ($health.status -eq "ok") "$($health.service) $($health.version)"
            }
            catch {
                Result "API /health" $false $_.Exception.Message
            }
        }

        $key.Dispose()
    }
}
finally {
    $base.Dispose()
}

Write-Host ""
Write-Host "Se StudentSecret/AdminSecret der ERRO, execute 07_REPARAR_SEGREDOS.cmd." -ForegroundColor Yellow
Write-Host "Nao ative o modo e-GOV exclusivo enquanto houver algum ERRO acima." -ForegroundColor Yellow
Read-Host "ENTER para fechar"
