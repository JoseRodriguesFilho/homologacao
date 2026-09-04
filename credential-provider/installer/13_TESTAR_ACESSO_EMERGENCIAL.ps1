#requires -Version 5.1
if ([Environment]::Is64BitOperatingSystem -and [IntPtr]::Size -eq 4) {
    $ps64 = Join-Path $env:WINDIR "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    $process = Start-Process $ps64 -Wait -PassThru -ArgumentList @(
        "-NoLogo", "-NoProfile", "-NoExit", "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )
    exit $process.ExitCode
}

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "EmergencyAccess.Common.ps1")
Ensure-EgovAdministrator $PSCommandPath

function Show-Result([string]$Name, [bool]$Ok, [string]$Detail = "") {
    $mark = if ($Ok) { "OK" } else { "ERRO" }
    $color = if ($Ok) { "Green" } else { "Red" }
    Write-Host ("{0,-30} {1,-5} {2}" -f $Name, $mark, $Detail) -ForegroundColor $color
}

$key = Open-EgovConfigKey $false $false
if ($null -eq $key) { throw "Configuracao e-GOV nao encontrada." }

try {
    $enabled = [int]$key.GetValue("EmergencyEnabled", 0) -eq 1
    $expiresUnix = [long]$key.GetValue("EmergencyExpiresUnix", 0)
    $expires = if ($expiresUnix -gt 0) {
        [DateTimeOffset]::FromUnixTimeSeconds($expiresUnix)
    } else { $null }

    $blob = $key.GetValue("EmergencySecret", $null)
    $binaryOk = $blob -is [byte[]] -and $blob.Length -gt 0
    $decryptOk = $false

    if ($binaryOk) {
        try {
            $plain = Unprotect-EgovEmergencyText ([byte[]]$blob)
            $decryptOk = $plain -match '^\d{12}$'
        }
        catch {}
        finally { $plain = $null }
    }

    $notExpired = $null -ne $expires -and $expires -gt [DateTimeOffset]::Now
    $name = [string]$key.GetValue("EmergencyDisplayName", "")
    $course = [string]$key.GetValue("EmergencyCourse", "")
    $version = [int]$key.GetValue("EmergencyVersion", 0)

    Write-Host ""
    Write-Host "TESTE DO ACESSO EMERGENCIAL e-GOV" -ForegroundColor Cyan
    Show-Result "Recurso ativado" $enabled
    Show-Result "Segredo REG_BINARY" $binaryOk
    Show-Result "Segredo DPAPI valido" $decryptOk "(codigo nao exibido)"
    Show-Result "Validade configurada" ($null -ne $expires) $(if ($expires) { $expires.LocalDateTime.ToString('dd/MM/yyyy HH:mm:ss') } else { "" })
    Show-Result "Dentro da validade" $notExpired
    Show-Result "Nome configurado" (-not [string]::IsNullOrWhiteSpace($name)) $name
    Show-Result "Curso configurado" (-not [string]::IsNullOrWhiteSpace($course)) $course
    Show-Result "Versao da configuracao" ($version -gt 0) $version

    Write-Host ""
    Write-Host "Este teste nao derruba a API e nao realiza login." -ForegroundColor Yellow
    Write-Host "Com a API respondendo, o Credential Provider recusara a contingencia por seguranca." -ForegroundColor Yellow
}
finally {
    $key.Dispose()
}

Write-Host ""
Read-Host "ENTER para fechar"
