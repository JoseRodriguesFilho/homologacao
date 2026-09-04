# Funcoes compartilhadas pelos scripts de contingencia e-GOV.
# Este arquivo nao deve ser executado diretamente.
$script:EgovConfigSubKey = "SOFTWARE\e-GOV\LabCPFProvider"

function Assert-EgovAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Execute este comando como Administrador."
    }
}

function Ensure-EgovAdministrator([string]$ScriptPath) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return
    }

    $ps64 = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    Start-Process $ps64 -Verb RunAs -ArgumentList (
        "-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File `"$ScriptPath`""
    )
    exit
}

function Initialize-EgovEmergencyDpapi {
    if ("EGOV.EmergencyDpapi" -as [type]) {
        return
    }

    $source = @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace EGOV
{
    public static class EmergencyDpapi
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

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr hMem);

        private const int UiForbidden = 0x1;
        private const int LocalMachine = 0x4;

        private static DATA_BLOB Allocate(byte[] input)
        {
            DATA_BLOB blob = new DATA_BLOB();
            blob.cbData = input.Length;
            blob.pbData = Marshal.AllocHGlobal(Math.Max(input.Length, 1));

            if (input.Length > 0)
                Marshal.Copy(input, 0, blob.pbData, input.Length);

            return blob;
        }

        private static void ZeroAndFree(ref DATA_BLOB blob)
        {
            if (blob.pbData == IntPtr.Zero)
                return;

            for (int i = 0; i < blob.cbData; i++)
                Marshal.WriteByte(blob.pbData, i, 0);

            Marshal.FreeHGlobal(blob.pbData);
            blob.pbData = IntPtr.Zero;
            blob.cbData = 0;
        }

        public static byte[] Protect(byte[] input)
        {
            if (input == null)
                throw new ArgumentNullException("input");

            DATA_BLOB inBlob = Allocate(input);
            DATA_BLOB outBlob = new DATA_BLOB();

            try
            {
                bool ok = CryptProtectData(
                    ref inBlob,
                    "e-GOV emergency access",
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    UiForbidden | LocalMachine,
                    out outBlob);

                if (!ok)
                    throw new Win32Exception(Marshal.GetLastWin32Error());

                byte[] result = new byte[outBlob.cbData];
                Marshal.Copy(outBlob.pbData, result, 0, outBlob.cbData);
                return result;
            }
            finally
            {
                ZeroAndFree(ref inBlob);

                if (outBlob.pbData != IntPtr.Zero)
                    LocalFree(outBlob.pbData);
            }
        }

        public static byte[] Unprotect(byte[] input)
        {
            if (input == null)
                throw new ArgumentNullException("input");

            DATA_BLOB inBlob = Allocate(input);
            DATA_BLOB outBlob = new DATA_BLOB();

            try
            {
                bool ok = CryptUnprotectData(
                    ref inBlob,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    UiForbidden,
                    out outBlob);

                if (!ok)
                    throw new Win32Exception(Marshal.GetLastWin32Error());

                byte[] result = new byte[outBlob.cbData];
                Marshal.Copy(outBlob.pbData, result, 0, outBlob.cbData);
                return result;
            }
            finally
            {
                ZeroAndFree(ref inBlob);

                if (outBlob.pbData != IntPtr.Zero)
                {
                    for (int i = 0; i < outBlob.cbData; i++)
                        Marshal.WriteByte(outBlob.pbData, i, 0);

                    LocalFree(outBlob.pbData);
                }
            }
        }
    }
}
"@

    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Protect-EgovEmergencyText([string]$PlainText) {
    Initialize-EgovEmergencyDpapi
    $bytes = [Text.Encoding]::Unicode.GetBytes($PlainText)

    try {
        return ,([byte[]][EGOV.EmergencyDpapi]::Protect($bytes))
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Unprotect-EgovEmergencyText([byte[]]$ProtectedBytes) {
    Initialize-EgovEmergencyDpapi
    $plainBytes = [EGOV.EmergencyDpapi]::Unprotect($ProtectedBytes)

    try {
        return [Text.Encoding]::Unicode.GetString($plainBytes).TrimEnd([char]0)
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Open-EgovConfigKey([bool]$Writable, [bool]$Create) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )

    try {
        if ($Create) {
            $key = $base.CreateSubKey(
                $script:EgovConfigSubKey,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
            )
        }
        else {
            $key = $base.OpenSubKey($script:EgovConfigSubKey, $Writable)
        }

        return $key
    }
    finally {
        $base.Dispose()
    }
}

function Protect-EgovConfigAcl {
    $registryPath = "HKLM:\$($script:EgovConfigSubKey)"
    $acl = New-Object System.Security.AccessControl.RegistrySecurity
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($sidText in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidText)
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            $sid,
            "FullControl",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )
        $acl.AddAccessRule($rule)
    }

    Set-Acl -Path $registryPath -AclObject $acl
}
