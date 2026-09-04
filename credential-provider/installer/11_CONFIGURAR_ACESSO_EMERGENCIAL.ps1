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

Write-Host ""
Write-Host "CONFIGURAR ACESSO EMERGENCIAL e-GOV" -ForegroundColor Cyan
Write-Host "Uso exclusivo do Aluno e-GOV quando o servidor local estiver indisponivel." -ForegroundColor Yellow
Write-Host "No login, deve estar selecionada a opcao Escola de Governo." -ForegroundColor Yellow
Write-Host "O codigo deve possuir exatamente 12 numeros." -ForegroundColor Yellow
Write-Host ""

function ConvertFrom-EgovSecureString([Security.SecureString]$Value) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Test-EgovCpfDigits([string]$Digits) {
    if ($Digits -notmatch '^\d{11}$' -or
        ($Digits.ToCharArray() | Select-Object -Unique).Count -eq 1) {
        return $false
    }

    $numbers = $Digits.ToCharArray() | ForEach-Object { [int]::Parse($_) }
    $sum = 0
    for ($i = 0; $i -lt 9; $i++) { $sum += $numbers[$i] * (10 - $i) }
    $first = ($sum * 10) % 11
    if ($first -eq 10) { $first = 0 }

    $sum = 0
    for ($i = 0; $i -lt 10; $i++) { $sum += $numbers[$i] * (11 - $i) }
    $second = ($sum * 10) % 11
    if ($second -eq 10) { $second = 0 }

    return $numbers[9] -eq $first -and $numbers[10] -eq $second
}

$secureCode1 = Read-Host "Codigo emergencial" -AsSecureString
$secureCode2 = Read-Host "Confirme o codigo" -AsSecureString
$code1 = ConvertFrom-EgovSecureString $secureCode1
$code2 = ConvertFrom-EgovSecureString $secureCode2

try {
    if ($code1 -notmatch '^\d{12}$') {
        throw "O codigo precisa ter exatamente 12 numeros."
    }

    if (-not [string]::Equals($code1, $code2, [StringComparison]::Ordinal)) {
        throw "Os codigos informados nao conferem."
    }

    if (Test-EgovCpfDigits $code1.Substring(0, 11)) {
        throw "Escolha outro codigo: os 11 primeiros numeros formam um CPF valido."
    }

    $daysText = Read-Host "Validade em dias [30]"
    if ([string]::IsNullOrWhiteSpace($daysText)) { $daysText = "30" }

    $validDays = 0
    if (-not [int]::TryParse($daysText, [ref]$validDays) -or
        $validDays -lt 1 -or $validDays -gt 365) {
        throw "A validade deve estar entre 1 e 365 dias."
    }

    $displayName = (Read-Host "Nome exibido [Aluno - Contingencia]").Trim()
    if (-not $displayName) { $displayName = "Aluno - Contingencia" }
    if ($displayName.Length -gt 80) { throw "Nome exibido muito longo (maximo 80)." }

    $course = (Read-Host "Curso exibido [Aula em modo de contingencia]").Trim()
    if (-not $course) { $course = "Aula em modo de contingencia" }
    if ($course.Length -gt 160) { throw "Curso exibido muito longo (maximo 160)." }

    $expires = [DateTimeOffset]::Now.AddDays($validDays)
    $protectedCode = Protect-EgovEmergencyText $code1
    $key = Open-EgovConfigKey $true $true

    if ($null -eq $key) { throw "Nao foi possivel abrir a configuracao Registry64." }

    try {
        Protect-EgovConfigAcl
        $oldVersion = [int]$key.GetValue("EmergencyVersion", 0)
        # Rotacao fail-closed: desativa antes de trocar qualquer componente.
        $key.SetValue("EmergencyEnabled", 0, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.Flush()
        $key.SetValue("EmergencySecret", [byte[]]$protectedCode, [Microsoft.Win32.RegistryValueKind]::Binary)
        $key.SetValue("EmergencyExpiresUnix", [long]$expires.ToUnixTimeSeconds(), [Microsoft.Win32.RegistryValueKind]::QWord)
        $key.SetValue("EmergencyDisplayName", $displayName, [Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue("EmergencyCourse", $course, [Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue("EmergencyVersion", $oldVersion + 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue("EmergencyEnabled", 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.Flush()
    }
    finally {
        $key.Dispose()
        [Array]::Clear($protectedCode, 0, $protectedCode.Length)
    }

    Write-Host ""
    Write-Host "Acesso emergencial configurado e ativado." -ForegroundColor Green
    Write-Host "Valido ate: $($expires.LocalDateTime.ToString('dd/MM/yyyy HH:mm:ss'))"
    Write-Host "Nao e necessario recompilar nem reinstalar a DLL." -ForegroundColor Cyan
}
finally {
    $code1 = $null
    $code2 = $null
    $secureCode1.Dispose()
    $secureCode2.Dispose()
}

Write-Host ""
Read-Host "ENTER para fechar"
