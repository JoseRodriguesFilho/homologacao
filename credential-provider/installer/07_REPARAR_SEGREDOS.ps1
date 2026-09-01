#requires -Version 5.1
$ErrorActionPreference = "Stop"

if ([Environment]::Is64BitOperatingSystem -and [IntPtr]::Size -eq 4) {
    $PS64 = Join-Path $env:WINDIR "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    & $PS64 -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($id)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $PS64 = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    Start-Process $PS64 -Verb RunAs -ArgumentList "-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop

if (-not ("EGOV.NativeDpapiRepair" -as [type])) {
    $source = @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace EGOV
{
    public static class NativeDpapiRepair
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

        [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CryptUnprotectData(
            ref DATA_BLOB pDataIn,
            IntPtr ppszDataDescr,
            IntPtr pOptionalEntropy,
            IntPtr pvReserved,
            IntPtr pPromptStruct,
            int dwFlags,
            out DATA_BLOB pDataOut);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr hMem);

        private const int UI_FORBIDDEN = 0x1;
        private const int LOCAL_MACHINE = 0x4;

        public static byte[] Protect(byte[] input)
        {
            return Transform(input, true);
        }

        public static byte[] Unprotect(byte[] input)
        {
            return Transform(input, false);
        }

        private static byte[] Transform(byte[] input, bool protect)
        {
            if (input == null || input.Length == 0)
                throw new ArgumentException("input vazio");

            DATA_BLOB inBlob = new DATA_BLOB();
            DATA_BLOB outBlob = new DATA_BLOB();
            IntPtr inputPtr = IntPtr.Zero;

            try
            {
                inputPtr = Marshal.AllocHGlobal(input.Length);
                Marshal.Copy(input, 0, inputPtr, input.Length);

                inBlob.cbData = input.Length;
                inBlob.pbData = inputPtr;

                bool ok;

                if (protect)
                {
                    ok = CryptProtectData(
                        ref inBlob,
                        "e-GOV Login local secret",
                        IntPtr.Zero,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        UI_FORBIDDEN | LOCAL_MACHINE,
                        out outBlob);
                }
                else
                {
                    ok = CryptUnprotectData(
                        ref inBlob,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        UI_FORBIDDEN,
                        out outBlob);
                }

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
                    for (int i = 0; i < input.Length; i++)
                        Marshal.WriteByte(inputPtr, i, 0);

                    Marshal.FreeHGlobal(inputPtr);
                }

                if (outBlob.pbData != IntPtr.Zero)
                    LocalFree(outBlob.pbData);
            }
        }
    }
}
"@

    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function New-RandomPassword {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $rng.GetBytes($bytes)
        return ([Convert]::ToBase64String($bytes) + "!Aa1")
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
        $rng.Dispose()
    }
}

function Write-Secret64([string]$Name, [byte[]]$Blob) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )

    try {
        $key = $base.CreateSubKey(
            "SOFTWARE\e-GOV\LabCPFProvider",
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
        )

        try {
            $key.SetValue(
                $Name,
                [byte[]]$Blob,
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

function Read-Secret64([string]$Name) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )

    try {
        $key = $base.OpenSubKey("SOFTWARE\e-GOV\LabCPFProvider", $false)

        if ($null -eq $key) {
            throw "Chave de configuracao e-GOV nao encontrada."
        }

        try {
            if ($key.GetValueKind($Name) -ne [Microsoft.Win32.RegistryValueKind]::Binary) {
                throw "$Name nao e REG_BINARY."
            }

            return ,([byte[]]$key.GetValue($Name))
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $base.Dispose()
    }
}

function Repair-One([string]$UserName, [string]$SecretName) {
    $user = Get-LocalUser -Name $UserName -ErrorAction Stop

    $plain = New-RandomPassword
    $secure = ConvertTo-SecureString $plain -AsPlainText -Force

    Set-LocalUser -Name $UserName -Password $secure

    $plainBytes = [Text.Encoding]::Unicode.GetBytes($plain)

    try {
        $blob = [byte[]][EGOV.NativeDpapiRepair]::Protect($plainBytes)
        Write-Secret64 -Name $SecretName -Blob $blob

        $stored = [byte[]](Read-Secret64 -Name $SecretName)
        $roundTrip = [byte[]][EGOV.NativeDpapiRepair]::Unprotect($stored)

        try {
            if ($roundTrip.Length -ne $plainBytes.Length) {
                throw "Round-trip DPAPI com tamanho divergente."
            }

            for ($i = 0; $i -lt $plainBytes.Length; $i++) {
                if ($roundTrip[$i] -ne $plainBytes[$i]) {
                    throw "Round-trip DPAPI divergente."
                }
            }
        }
        finally {
            [Array]::Clear($roundTrip, 0, $roundTrip.Length)
            [Array]::Clear($stored, 0, $stored.Length)
            [Array]::Clear($blob, 0, $blob.Length)
        }
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        $plain = $null
        $secure = $null
    }

    Write-Host "$SecretName OK para $UserName." -ForegroundColor Green
}

Write-Host ""
Write-Host "Reparando segredos locais e-GOV..." -ForegroundColor Cyan

Repair-One -UserName "AlunoEGOV" -SecretName "StudentSecret"
Repair-One -UserName "AdminEGOV" -SecretName "AdminSecret"

Write-Host ""
Write-Host "DPAPI + Registry64 validados com round-trip." -ForegroundColor Green
Write-Host "Bloqueie o Windows e teste novamente." -ForegroundColor Cyan
