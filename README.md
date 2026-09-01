# e-GOV Login v11-homolog

Versao de homologacao do login e-GOV com CPF para os demais usuarios e matricula para alunos UNIVESP.

> Para o procedimento desta homologacao, consulte `V11-HOMOLOGACAO.md`.

## Exibicao no Windows

As contas tecnicas internas sao:

```text
Usuario interno: AlunoEGOV
Nome exibido:    Aluno e-GOV

Usuario interno: AdminEGOV
Nome exibido:    Admin e-GOV
```

O aluno/professor nao ve nem conhece a senha local. As senhas sao geradas
aleatoriamente durante a instalacao e armazenadas com DPAPI LocalMachine.

## Perfis da API

```text
aluno
professor
admin
```

### aluno

- usa a tile `Aluno e-GOV`;
- nao e administrador local;
- somente uma sessao ativa por CPF;
- o mesmo CPF nao entra em outra maquina enquanto estiver ONLINE;
- pode retomar a propria sessao na mesma maquina;
- nao pode assumir a sessao de outro aluno.

### professor

- usa a tile `Aluno e-GOV`;
- NAO possui privilegio administrativo;
- pode desbloquear uma sessao de aluno ja ativa naquele computador;
- a API registra quem realizou o desbloqueio.

### admin

- usa a tile `Admin e-GOV`;
- entra na conta tecnica `AdminEGOV`;
- essa conta pertence ao grupo Administradores;
- o CPF precisa ter `role=admin` na API.

## CPF

O campo aceita somente:

```text
0-9
.
-
```

A mascara e aplicada automaticamente:

```text
SEU_CPF_DE_TESTE
->
000.000.000-00
```

Quando os 11 digitos estao completos, o Credential Provider consulta:

```text
POST /auth/preview
```

e exibe o nome da pessoa antes do login.

Ao pressionar Entrar, consulta:

```text
POST /auth/cpf
```

A autorizacao e feita em tempo real pela API.

## Controle de sessoes

A API cria um `session_id`.

O servico Windows:

```text
e-GOV Lab CPF Agent
```

fica registrado no Service Control Manager e roda como `LocalSystem`.

Ele envia heartbeat a cada 30 segundos contendo:

```text
session_id
computer
IPv4
MAC
```

A API considera a sessao expirada depois de 180 segundos sem heartbeat
(valor configuravel).

O Agent verifica a presenca da conta Windows a cada 5 segundos. Quando
detecta logoff, envia `/sessions/logout`.

Se houver desligamento, travamento ou perda da maquina, a API libera a sessao
automaticamente pelo timeout de heartbeat.

## Regra de sessao unica do aluno

Exemplo:

```text
CPF 000.000.000-00
LAB-PC07 = ACTIVE

tentativa em LAB-PC12
-> NEGADA
-> CPF ja conectado em LAB-PC07.
```

Se o mesmo aluno voltar a tela bloqueada no `LAB-PC07`, a propria sessao pode
ser retomada.

A regra de uma maquina por CPF vale somente para `role=aluno`.

## Estrutura do projeto

```text
api/
agent/
credential-provider/
.github/workflows/build.yml
```

## Atualizando a API v7 para v8

A API v8 aceita tanto as variaveis novas:

```text
EGOV_API_TOKEN
EGOV_ADMIN_TOKEN
EGOV_SEED_CPF
EGOV_SEED_NAME
```

quanto as antigas da v7:

```text
LAB_API_TOKEN
LAB_ADMIN_TOKEN
LAB_SEED_CPF
LAB_SEED_NAME
```

O compose usa o banco:

```text
/data/labcpf.db
```

para permitir a migracao dos cadastros da tabela `students` da v7 para
`people` na v8.

No servidor:

```bash
cd api
docker compose down
docker compose up -d --build
curl http://127.0.0.1:8089/health
```

No proxy reverso, mantenha:

```text
https://egov.francodarocha.sp.gov.br
      ->
http://192.168.0.244:8089
```

## Cadastrar pessoas

Aluno:

```bash
./USUARIO.sh SEU_CPF_DE_TESTE "Joao da Silva" aluno
```

Professor:

```bash
./USUARIO.sh CPF "Maria Professora" professor
```

Administrador e-GOV:

```bash
./USUARIO.sh CPF "Administrador TI" admin
```

Listar:

```bash
./LISTAR_USUARIOS.sh
```

Online:

```bash
./SESSOES_ONLINE.sh
```

Historico:

```bash
./HISTORICO.sh
```

## Compilar Windows

Suba todo este projeto para o GitHub.

Execute:

```text
Actions
-> Build e-GOV Login v8
-> Run workflow
```

Artifact esperado:

```text
eGOV-Login-v8-Windows-x64
```

Ele contem:

```text
LabCPFProvider.dll
eGOVLabCPFAgent.exe

01_INSTALAR.cmd
02_CONFIGURAR_API.cmd
03_TESTAR_API.cmd
04_ATIVAR_MODO_EGOV.cmd
05_ATIVAR_MODO_MANUTENCAO.cmd
06_DESINSTALAR.cmd

EMERGENCIA_REMOVER_POLITICAS.reg
README.md
SHA256.txt
```

## Instalacao Windows

Primeiro mantenha os providers nativos disponiveis.

Execute:

```text
01_INSTALAR.cmd
```

O instalador:

- cria/ajusta `AlunoEGOV`;
- define nome exibido `Aluno e-GOV`;
- garante `Aluno e-GOV` no grupo local Users/Usuarios;
- garante que `Aluno e-GOV` NAO seja administrador;
- cria/ajusta `AdminEGOV`;
- define nome exibido `Admin e-GOV`;
- coloca `Admin e-GOV` em Administradores;
- gera senhas locais aleatorias;
- protege as senhas com DPAPI LocalMachine;
- instala a DLL;
- instala e inicia o Windows Service;
- registra o Credential Provider.

Depois:

```text
02_CONFIGURAR_API.cmd
```

URL:

```text
https://egov.francodarocha.sp.gov.br
```

Informe `EGOV_API_TOKEN` ou o token de cliente atualmente usado pela API.

Teste:

```text
03_TESTAR_API.cmd
```

Antes de ativar o modo exclusivo, bloqueie o Windows e teste manualmente as
tiles `Aluno e-GOV` e `Admin e-GOV`.

Somente depois:

```text
04_ATIVAR_MODO_EGOV.cmd
```

Esse modo usa `ExcludedCredentialProviders`, portanto os providers nativos
ficam indisponiveis na tela normal.

Para manutencao:

```text
05_ATIVAR_MODO_MANUTENCAO.cmd
```

## Recuperacao

O arquivo:

```text
EMERGENCIA_REMOVER_POLITICAS.reg
```

remove as politicas que excluem os providers nativos.

Como essa camada altera o LogonUI, teste a primeira compilacao em VM/snapshot
antes de distribuir para as maquinas do laboratorio.

## Seguranca

A v8 remove a senha fixa da DLL.

As senhas de `AlunoEGOV` e `AdminEGOV` sao aleatorias por maquina e ficam
criptografadas com DPAPI LocalMachine em:

```text
HKLM\SOFTWARE\e-GOV\LabCPFProvider
```

A chave e restrita a:

```text
SYSTEM
Administradores
```

O Credential Provider exige HTTPS por padrao.

GUID do Credential Provider:

```text
{D2D9E531-8DB1-4C83-ABF9-810F70A1EB09}
```


## Correção v8.1

Corrige o build do `eGOVLabCPFAgent.exe` adicionando o namespace:

```csharp
using System.IO.Pipes;
```

Ele é necessário para `NamedPipeServerStream`, `PipeDirection`,
`PipeTransmissionMode` e `PipeOptions`.


## Correção v8.2

O `prepare-source.ps1` não usa mais correspondência textual exata no bloco
`PKEY_Identity_QualifiedUserName`. O GitHub Actions pode baixar o fonte da
Microsoft com LF enquanto o script é interpretado com CRLF, fazendo
`Contains()` falhar mesmo com o código presente.

A v8.2 usa regex tolerante a LF/CRLF tanto para o bloco
`QualifiedUserName` quanto para o final de `GetSerialization`.


## Correção v8.3

Corrige a instalação em Windows x64 quando o `.cmd` é iniciado a partir de um
processo 32-bit. Nesse cenário o Windows pode abrir o PowerShell 32-bit, no qual
o módulo `Microsoft.PowerShell.LocalAccounts` não fica disponível.

A v8.3:

- força `WindowsPowerShell` 64-bit nos arquivos `.cmd`;
- faz auto-reexecução em 64-bit caso algum `.ps1` seja iniciado em 32-bit;
- valida explicitamente a presença de `Microsoft.PowerShell.LocalAccounts`;
- mantém a criação das contas por SID/grupo sem depender do idioma do Windows.


## Correção v8.4

Corrige um BOM UTF-8 duplicado que podia ficar imediatamente antes de
`#requires -Version 5.1` no `01_INSTALAR.ps1`. Nesse caso o Windows PowerShell
interpretava a diretiva como um comando (`# requires`) em vez de comentário/diretiva.

A v8.4 normaliza todos os `.ps1` para:

1. exatamente um BOM UTF-8;
2. `#requires -Version 5.1` como primeira linha textual;
3. reexecução 64-bit somente depois da diretiva `#requires`.


## Correção v8.5 — erros sempre visíveis

Os `.cmd` agora abrem o Windows PowerShell 64-bit com `-NoExit`, então a
janela não fecha quando ocorre um erro.

Cada script grava também um arquivo `.log` na mesma pasta.

Para trabalhar diretamente no PowerShell:

```text
00_ABRIR_POWERSHELL_ADMIN.cmd
```

Depois execute:

```powershell
.\01_INSTALAR.ps1
```


## Correção v8.6 — DPAPI no Windows PowerShell 5.1

O instalador agora carrega explicitamente o assembly `System.Security` antes de
usar:

```powershell
[System.Security.Cryptography.ProtectedData]
[System.Security.Cryptography.DataProtectionScope]
```

Isso corrige o erro:

```text
Não é possível localizar o tipo [Security.Cryptography.ProtectedData]
```

As contas que já tenham sido criadas por uma tentativa anterior podem permanecer;
é seguro executar `01_INSTALAR.ps1` novamente.


## Correção v8.7 — DPAPI nativa

A proteção das senhas locais não usa mais a classe .NET
`System.Security.Cryptography.ProtectedData`.

O instalador chama diretamente a API nativa do Windows:

```text
crypt32.dll -> CryptProtectData
```

com:

```text
CRYPTPROTECT_LOCAL_MACHINE
CRYPTPROTECT_UI_FORBIDDEN
```

Isso elimina a dependência do assembly `System.Security` no Windows PowerShell 5.1.
A DLL do Credential Provider continua lendo o mesmo blob com `CryptUnprotectData`.


## Correção v8.8 — máscara de CPF

O campo CPF agora foi ajustado para o comportamento:

```text
000.000.000-00
```

Regras:

- o usuário digita somente `0` a `9`;
- ponto e hífen são inseridos exclusivamente pelo Credential Provider;
- máximo de 11 dígitos;
- 12º dígito é rejeitado e o valor anterior é restaurado;
- letras, espaços e símbolos são rejeitados;
- ponto/hífen digitados manualmente são rejeitados;
- ao apagar ou substituir números, a máscara é reconstruída a partir dos dígitos;
- o campo não é reescrito pelo LogonUI em toda tecla: `SetFieldString` só é
  chamado quando a pontuação realmente precisa mudar, reduzindo problemas de
  cursor durante edição no meio do CPF;
- `/auth/preview` só é consultado quando existem 11 dígitos e o CPF mudou.
