# e-GOV Login v11 - Homologação

Objetivo desta versão: permitir dois tipos de identificação na tile **Aluno e-GOV**.

- **Outros - CPF**: mantém a validação de CPF da v10.
- **UNIVESP - Matrícula**: aceita matrícula numérica e consulta a API sem validar dígitos de CPF.
- **Admin e-GOV**: continua usando CPF, mesmo que o dropdown esteja visível.

## Tela esperada

Na tile `Aluno e-GOV` aparece o dropdown:

```text
Outros - CPF
UNIVESP - Matrícula
```

Abaixo dele existe um único campo `CPF / Matrícula`.

Ao escolher `Outros - CPF`, o eco mostra:

```text
CPF: 529.982.247-25
```

Ao escolher `UNIVESP - Matrícula`, o eco mostra:

```text
Matrícula: 12345678
```

## Atualizar a API de homologação

Antes, faça backup do banco:

```bash
cd api
cp -a data/labcpf.db data/labcpf.db.backup-v10
```

Depois:

```bash
docker compose down
docker compose up -d --build
curl http://127.0.0.1:8089/health
```

O banco v10 é migrado automaticamente. CPFs existentes passam a ser tratados como:

```text
institution=outros
identifier_type=cpf
```

## Cadastrar um aluno UNIVESP

```bash
cd api
./USUARIO.sh matricula 12345678 "Aluno Teste UNIVESP" aluno
```

## Cadastrar um usuário por CPF

```bash
./USUARIO.sh cpf 52998224725 "Aluno Teste CPF" aluno
```

Professor e administrador permanecem por CPF:

```bash
./USUARIO.sh cpf 52998224725 "Professor Teste" professor
./USUARIO.sh cpf 52998224725 "Administrador Teste" admin
```

## Testar somente a API

Depois de cadastrar os dois usuários:

```bash
./TESTAR_V11.sh 52998224725 12345678
```

O primeiro teste usa `Outros/CPF`; o segundo usa `UNIVESP/Matrícula`.

## Build do Credential Provider

O Credential Provider é C++/Windows e precisa ser compilado em Windows/MSBuild. O workflow do GitHub Actions já foi ajustado para gerar:

```text
eGOV-Login-v11-HOMOLOG-Windows11Pro-x64
```

Faça push deste projeto para o GitHub e execute o workflow **Build e-GOV Login v11 Homolog**. O artifact conterá a nova DLL, Agent e instalador.

## Homologação recomendada

Use uma VM Windows 11 ou uma máquina física de teste. Não instale esta build primeiro em um laboratório de produção.

Valide, nesta ordem:

1. `Outros - CPF` com CPF válido cadastrado.
2. CPF inválido.
3. `UNIVESP - Matrícula` com matrícula cadastrada.
4. Matrícula inexistente.
5. Tentativa da mesma matrícula em duas máquinas.
6. Professor por CPF.
7. Admin e-GOV por CPF.
8. Reinício/logoff e heartbeat do Agent.

## Compatibilidade

A rota nova de autenticação é:

```text
POST /auth/login
```

A API mantém também `POST /auth/cpf` para compatibilidade com clientes v10 durante a homologação.
