#requires -Version 5.1
$ErrorActionPreference = "Stop"

$ExpectedDll = "6BCED51BF8A902EB8521E74FAC88A5AB48309247D24604AA5B5223BD51C468D8"
$ExpectedAgent = "BC0859421613CE807664C69358A3076B8C6B46E702340831AAC57BA279CBD360"

$Dll = Join-Path $PSScriptRoot "LabCPFProvider.dll"
$Agent = Join-Path $PSScriptRoot "eGOVLabCPFAgent.exe"

if (-not (Test-Path $Dll)) {
    throw "LabCPFProvider.dll nao encontrado."
}

if (-not (Test-Path $Agent)) {
    throw "eGOVLabCPFAgent.exe nao encontrado."
}

$DllHash = (Get-FileHash $Dll -Algorithm SHA256).Hash.ToUpperInvariant()
$AgentHash = (Get-FileHash $Agent -Algorithm SHA256).Hash.ToUpperInvariant()

Write-Host ""
Write-Host "Verificacao do pacote e-GOV v9.5" -ForegroundColor Cyan
Write-Host "DLL   : $DllHash"
Write-Host "Agent : $AgentHash"
Write-Host ""

if ($DllHash -ne $ExpectedDll) {
    throw "Hash da LabCPFProvider.dll divergente."
}

if ($AgentHash -ne $ExpectedAgent) {
    throw "Hash do eGOVLabCPFAgent.exe divergente."
}

Write-Host "ARQUIVOS OK." -ForegroundColor Green
Write-Host "Pode executar 01_INSTALAR.cmd." -ForegroundColor Cyan
Read-Host "ENTER para fechar"
