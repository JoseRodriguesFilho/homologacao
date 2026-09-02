#requires -Version 5.1
$ErrorActionPreference = "Stop"

$ExpectedDll = "6BCED51BF8A902EB8521E74FAC88A5AB48309247D24604AA5B5223BD51C468D8"
$ExpectedAgent = "BC0859421613CE807664C69358A3076B8C6B46E702340831AAC57BA279CBD360"

$Dll = Join-Path $PSScriptRoot "LabCPFProvider.dll"
$Agent = Join-Path $PSScriptRoot "eGOVLabCPFAgent.exe"
$Manifest = Join-Path $PSScriptRoot "SHA256.txt"

if (-not (Test-Path $Dll)) {
    throw "LabCPFProvider.dll nao encontrado."
}

if (-not (Test-Path $Agent)) {
    throw "eGOVLabCPFAgent.exe nao encontrado."
}

# Builds novos levam o manifesto ao lado dos binarios. Ele e a fonte dos
# hashes daquele artefato; os valores acima permanecem apenas para pacotes
# antigos que ainda nao possuem SHA256.txt.
if (Test-Path $Manifest) {
    $ManifestDll = $null
    $ManifestAgent = $null

    foreach ($Line in Get-Content $Manifest) {
        if ($Line -match '^(?<hash>[A-Fa-f0-9]{64})\s+\*?(?<file>.+?)\s*$') {
            $FileName = [IO.Path]::GetFileName($Matches.file)

            if ($FileName -ieq "LabCPFProvider.dll") {
                $ManifestDll = $Matches.hash.ToUpperInvariant()
            }
            elseif ($FileName -ieq "eGOVLabCPFAgent.exe") {
                $ManifestAgent = $Matches.hash.ToUpperInvariant()
            }
        }
    }

    if (-not $ManifestDll -or -not $ManifestAgent) {
        throw "SHA256.txt nao contem os dois binarios esperados."
    }

    $ExpectedDll = $ManifestDll
    $ExpectedAgent = $ManifestAgent
}

$DllHash = (Get-FileHash $Dll -Algorithm SHA256).Hash.ToUpperInvariant()
$AgentHash = (Get-FileHash $Agent -Algorithm SHA256).Hash.ToUpperInvariant()

Write-Host ""
Write-Host "Verificacao do pacote e-GOV v11" -ForegroundColor Cyan
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
if (-not $env:CI) {
    Read-Host "ENTER para fechar"
}
