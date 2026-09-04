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

$key = Open-EgovConfigKey $true $false
if ($null -eq $key) { throw "Configuracao e-GOV nao encontrada." }

try {
    $oldVersion = [int]$key.GetValue("EmergencyVersion", 0)
    $key.SetValue("EmergencyEnabled", 0, [Microsoft.Win32.RegistryValueKind]::DWord)
    $key.SetValue("EmergencyVersion", $oldVersion + 1, [Microsoft.Win32.RegistryValueKind]::DWord)

    foreach ($name in @(
        "EmergencySecret", "EmergencyExpiresUnix",
        "EmergencyDisplayName", "EmergencyCourse"
    )) {
        $key.DeleteValue($name, $false)
    }

    $key.Flush()
}
finally {
    $key.Dispose()
}

Protect-EgovConfigAcl
Write-Host ""
Write-Host "Acesso emergencial desativado e o segredo local foi removido." -ForegroundColor Green
Write-Host "Nao e necessario recompilar nem reinstalar a DLL." -ForegroundColor Cyan
Write-Host ""
Read-Host "ENTER para fechar"
