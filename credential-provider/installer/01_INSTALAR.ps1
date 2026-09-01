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

$LogPath = Join-Path $PSScriptRoot "01_INSTALAR.log"
try {
    Start-Transcript -Path $LogPath -Append -Force | Out-Null
}
catch {
    # Nao interrompe o script se o transcript nao puder ser iniciado.
}

$Guid = "{D2D9E531-8DB1-4C83-ABF9-810F70A1EB09}"
$OldGuid = "{5FD3D285-0DD9-4362-8855-E0ABAACD4AF6}"

$StudentUser = "AlunoEGOV"
$StudentDisplay = "Aluno e-GOV"

$AdminUser = "AdminEGOV"
$AdminDisplay = "Admin e-GOV"

$DllSource = Join-Path $PSScriptRoot "LabCPFProvider.dll"
$AgentSource = Join-Path $PSScriptRoot "eGOVLabCPFAgent.exe"

$DllTarget = "$env:WINDIR\System32\LabCPFProvider.dll"
$ProgramDir = "$env:ProgramFiles\e-GOV\LabCPF"
$AgentTarget = Join-Path $ProgramDir "eGOVLabCPFAgent.exe"

$Providers = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"
$Clsid = "Registry::HKEY_CLASSES_ROOT\CLSID"
$UserTile = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\UserTile"
$ConfigKey = "HKLM:\SOFTWARE\e-GOV\LabCPFProvider"

function Ensure-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $PowerShell64 = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
        Start-Process $PowerShell64 -Verb RunAs -ArgumentList "-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    }
}

function New-RandomPassword {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    return ([Convert]::ToBase64String($bytes) + "!Aa1")
}

function Protect-Secret([string]$PlainText) {
    # Usa a API nativa do Windows (CryptProtectData), sem depender de
    # System.Security.Cryptography.ProtectedData do .NET/PowerShell.
    if (-not ("EGOV.NativeDpapi" -as [type])) {
        $source = @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace EGOV
{
    public static class NativeDpapi
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct DATA_BLOB
        {
            public int cbData;
            public IntPtr pbData;
        }

        [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CryptProtectData(
            ref DATA_BLOB pDataIn,
            string szDataDescr,
            IntPtr pOptionalEntropy,
            IntPtr pvReserved,
            IntPtr pPromptStruct,
            int dwFlags,
            out DATA_BLOB pDataOut);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr hMem);

        private const int CRYPTPROTECT_UI_FORBIDDEN = 0x1;
        private const int CRYPTPROTECT_LOCAL_MACHINE = 0x4;

        public static byte[] Protect(byte[] input)
        {
            if (input == null)
                throw new ArgumentNullException("input");

            DATA_BLOB inBlob = new DATA_BLOB();
            DATA_BLOB outBlob = new DATA_BLOB();

            IntPtr inputPtr = IntPtr.Zero;

            try
            {
                int length = input.Length;

                // CryptProtectData aceita cbData=0, mas as senhas nunca devem ser vazias.
                inputPtr = Marshal.AllocHGlobal(Math.Max(length, 1));

                if (length > 0)
                    Marshal.Copy(input, 0, inputPtr, length);

                inBlob.cbData = length;
                inBlob.pbData = inputPtr;

                bool ok = CryptProtectData(
                    ref inBlob,
                    "e-GOV Login local secret",
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    CRYPTPROTECT_UI_FORBIDDEN | CRYPTPROTECT_LOCAL_MACHINE,
                    out outBlob);

                if (!ok)
                    throw new Win32Exception(Marshal.GetLastWin32Error());

                byte[] result = new byte[outBlob.cbData];
                Marshal.Copy(outBlob.pbData, result, 0, outBlob.cbData);
                return result;
            }
            finally
            {
                if (inputPtr != IntPtr.Zero)
                {
                    // Limpa o buffer de entrada antes de liberar.
                    for (int i = 0; i < input.Length; i++)
                        Marshal.WriteByte(inputPtr, i, 0);

                    Marshal.FreeHGlobal(inputPtr);
                }

                if (outBlob.pbData != IntPtr.Zero)
                {
                    // O blob protegido nao e plaintext, mas ainda liberamos corretamente.
                    LocalFree(outBlob.pbData);
                }
            }
        }
    }
}
"@

        Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
    }

    $bytes = [Text.Encoding]::Unicode.GetBytes($PlainText)

    try {
        $blob = [EGOV.NativeDpapi]::Protect($bytes)
        return ,([byte[]]$blob)
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}


function Set-Registry64Binary(
    [string]$SubKey,
    [string]$Name,
    [byte[]]$Value
) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )

    try {
        $key = $base.CreateSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
        )

        if ($null -eq $key) {
            throw "Nao foi possivel abrir HKLM:\$SubKey em Registry64."
        }

        try {
            $key.SetValue(
                $Name,
                [byte[]]$Value,
                [Microsoft.Win32.RegistryValueKind]::Binary
            )
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $base.Dispose()
    }
}

function Ensure-LocalAccount(
    [string]$Name,
    [string]$DisplayName,
    [bool]$IsAdmin,
    [string]$Password
) {
    $localAccounts = Get-Module -ListAvailable -Name Microsoft.PowerShell.LocalAccounts |
        Select-Object -First 1

    if ($null -eq $localAccounts) {
        $modulePath = Join-Path $env:WINDIR `
            "System32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.LocalAccounts\Microsoft.PowerShell.LocalAccounts.psd1"

        if (Test-Path $modulePath) {
            Import-Module $modulePath -ErrorAction Stop
        }
        else {
            throw "Modulo Microsoft.PowerShell.LocalAccounts nao encontrado. Processo 64-bit: $([Environment]::Is64BitProcess). Windows 64-bit: $([Environment]::Is64BitOperatingSystem)."
        }
    }
    else {
        Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop
    }

    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    $user = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue

    if ($null -eq $user) {
        Write-Host "Criando $DisplayName..." -ForegroundColor Cyan

        New-LocalUser `
            -Name $Name `
            -FullName $DisplayName `
            -Description "Conta tecnica do e-GOV Login" `
            -Password $secure `
            -PasswordNeverExpires `
            -UserMayNotChangePassword | Out-Null
    }
    else {
        Write-Host "$DisplayName ja existe; ajustando configuracao..." -ForegroundColor Yellow

        Set-LocalUser `
            -Name $Name `
            -FullName $DisplayName `
            -Description "Conta tecnica do e-GOV Login" `
            -Password $secure `
            -PasswordNeverExpires $true `
            -UserMayChangePassword $false

        if (-not $user.Enabled) {
            Enable-LocalUser -Name $Name
        }
    }

    $usersGroup = Get-LocalGroup -SID "S-1-5-32-545" -ErrorAction Stop
    $adminsGroup = Get-LocalGroup -SID "S-1-5-32-544" -ErrorAction Stop

    $memberUsers = Get-LocalGroupMember -Group $usersGroup.Name -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq "$env:COMPUTERNAME\$Name" -or
            $_.Name -ieq $Name
        }

    if (-not $memberUsers) {
        Add-LocalGroupMember -Group $usersGroup.Name -Member $Name
        Write-Host "$DisplayName adicionado ao grupo $($usersGroup.Name)." -ForegroundColor Green
    }

    $memberAdmins = Get-LocalGroupMember -Group $adminsGroup.Name -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq "$env:COMPUTERNAME\$Name" -or
            $_.Name -ieq $Name
        }

    if ($IsAdmin) {
        if (-not $memberAdmins) {
            Add-LocalGroupMember -Group $adminsGroup.Name -Member $Name
            Write-Host "$DisplayName adicionado ao grupo $($adminsGroup.Name)." -ForegroundColor Green
        }
    }
    else {
        if ($memberAdmins) {
            Remove-LocalGroupMember -Group $adminsGroup.Name -Member $Name
            Write-Host "$DisplayName removido do grupo $($adminsGroup.Name)." -ForegroundColor Green
        }
    }
}

function Protect-ConfigRegistry {
    New-Item $ConfigKey -Force | Out-Null

    $acl = New-Object System.Security.AccessControl.RegistrySecurity
    $acl.SetAccessRuleProtection($true, $false)

    $systemSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")

    $systemRule = New-Object System.Security.AccessControl.RegistryAccessRule(
        $systemSid,
        "FullControl",
        "ContainerInherit,ObjectInherit",
        "None",
        "Allow"
    )

    $adminRule = New-Object System.Security.AccessControl.RegistryAccessRule(
        $adminsSid,
        "FullControl",
        "ContainerInherit,ObjectInherit",
        "None",
        "Allow"
    )

    $acl.AddAccessRule($systemRule)
    $acl.AddAccessRule($adminRule)

    Set-Acl -Path $ConfigKey -AclObject $acl
}

Ensure-Admin

if (-not (Test-Path $DllSource)) {
    throw "LabCPFProvider.dll nao encontrado no pacote."
}

if (-not (Test-Path $AgentSource)) {
    throw "eGOVLabCPFAgent.exe nao encontrado no pacote."
}

Write-Host ""
Write-Host "Instalando e-GOV Login v9.5" -ForegroundColor Cyan
Write-Host ""

$studentPassword = New-RandomPassword
$adminPassword = New-RandomPassword

Ensure-LocalAccount `
    -Name $StudentUser `
    -DisplayName $StudentDisplay `
    -IsAdmin $false `
    -Password $studentPassword

Ensure-LocalAccount `
    -Name $AdminUser `
    -DisplayName $AdminDisplay `
    -IsAdmin $true `
    -Password $adminPassword

Protect-ConfigRegistry

$studentProtected = Protect-Secret $studentPassword
$adminProtected = Protect-Secret $adminPassword

Set-Registry64Binary `
    -SubKey "SOFTWARE\e-GOV\LabCPFProvider" `
    -Name "StudentSecret" `
    -Value ([byte[]]$studentProtected)

Set-Registry64Binary `
    -SubKey "SOFTWARE\e-GOV\LabCPFProvider" `
    -Name "AdminSecret" `
    -Value ([byte[]]$adminProtected)

$studentPassword = $null
$adminPassword = $null

$serviceName = "eGOVLabCPFAgent"
$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($existingService) {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
}

Copy-Item $DllSource $DllTarget -Force

New-Item -ItemType Directory -Force $ProgramDir | Out-Null
Copy-Item $AgentSource $AgentTarget -Force

Remove-Item "$Providers\$OldGuid" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$Clsid\$OldGuid" -Recurse -Force -ErrorAction SilentlyContinue

New-Item "$Providers\$Guid" -Force | Out-Null
Set-Item "$Providers\$Guid" -Value "e-GOV Login"

New-Item "$Clsid\$Guid" -Force | Out-Null
Set-Item "$Clsid\$Guid" -Value "e-GOV Login"

New-Item "$Clsid\$Guid\InprocServer32" -Force | Out-Null
Set-Item "$Clsid\$Guid\InprocServer32" -Value $DllTarget

New-ItemProperty `
    "$Clsid\$Guid\InprocServer32" `
    -Name ThreadingModel `
    -PropertyType String `
    -Value "Apartment" `
    -Force | Out-Null

$studentSid = (Get-LocalUser -Name $StudentUser -ErrorAction Stop).SID.Value
$adminSid = (Get-LocalUser -Name $AdminUser -ErrorAction Stop).SID.Value

New-Item "$UserTile\$studentSid" -Force | Out-Null
Set-Item "$UserTile\$studentSid" -Value $Guid

New-Item "$UserTile\$adminSid" -Force | Out-Null
Set-Item "$UserTile\$adminSid" -Value $Guid

if ($existingService) {
    & sc.exe config $serviceName `
        binPath= "`"$AgentTarget`"" `
        start= auto `
        obj= LocalSystem `
        DisplayName= "e-GOV Lab CPF Agent" | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao atualizar o servico eGOVLabCPFAgent."
    }
}
else {
    & sc.exe create $serviceName `
        binPath= "`"$AgentTarget`"" `
        start= auto `
        obj= LocalSystem `
        DisplayName= "e-GOV Lab CPF Agent" | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao criar o servico eGOVLabCPFAgent."
    }
}

& sc.exe description $serviceName "Heartbeat, IP, MAC e controle de sessoes do e-GOV Login." | Out-Null
& sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

Start-Service -Name $serviceName

$dllOk = Test-Path $DllTarget
$providerOk = Test-Path "$Providers\$Guid"
$studentOk = $null -ne (Get-LocalUser -Name $StudentUser -ErrorAction SilentlyContinue)
$adminOk = $null -ne (Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue)
$agentOk = (Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status -eq "Running"

Write-Host ""
Write-Host "Verificacao final:" -ForegroundColor Cyan
Write-Host "  Aluno e-GOV : $studentOk"
Write-Host "  Admin e-GOV : $adminOk"
Write-Host "  DLL          : $dllOk"
Write-Host "  Provider     : $providerOk"
Write-Host "  Agent        : $agentOk"
Write-Host ""

if (-not ($studentOk -and $adminOk -and $dllOk -and $providerOk -and $agentOk)) {
    throw "Instalacao incompleta."
}

Write-Host "e-GOV Login v9.5 instalado." -ForegroundColor Green
Write-Host "Agora execute 02_CONFIGURAR_API.cmd." -ForegroundColor Cyan
Read-Host "ENTER para fechar"
