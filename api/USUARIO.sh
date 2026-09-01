#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -lt 4 ]; then
  echo "Uso:"
  echo "  $0 cpf CPF \"Nome Completo\" aluno"
  echo "  $0 cpf CPF \"Nome Completo\" professor"
  echo "  $0 cpf CPF \"Nome Completo\" admin"
  echo "  $0 matricula MATRICULA \"Nome Completo\" aluno"
  exit 1
fi

TYPE="$1"
IDENTIFIER="$2"
NAME="$3"
ROLE="$4"

case "$TYPE" in cpf|matricula) ;; *) echo "Tipo invalido: $TYPE"; exit 1;; esac
case "$ROLE" in aluno|professor|admin) ;; *) echo "Role invalida: $ROLE"; exit 1;; esac

if [ "$TYPE" = "matricula" ]; then
  INSTITUTION="univesp"
  if [ "$ROLE" != "aluno" ]; then
    echo "Matricula UNIVESP permitida apenas para role aluno nesta homologacao."
    exit 1
  fi
else
  INSTITUTION="outros"
fi

set -a
source ./.env
set +a
ADMIN_TOKEN="${EGOV_ADMIN_TOKEN:-${LAB_ADMIN_TOKEN:-}}"
[ -n "$ADMIN_TOKEN" ] || { echo "Token administrativo nao encontrado no .env"; exit 1; }

python3 - "$TYPE" "$IDENTIFIER" "$NAME" "$ROLE" "$INSTITUTION" "$ADMIN_TOKEN" <<'PY2'
import json,sys,urllib.request
itype,identifier,name,role,institution,token=sys.argv[1:]
body=json.dumps({"identifier":identifier,"identifier_type":itype,"institution":institution,"name":name,"role":role,"active":True}).encode()
req=urllib.request.Request("http://127.0.0.1:8089/admin/people",data=body,headers={"Content-Type":"application/json","X-Admin-Token":token},method="POST")
print(urllib.request.urlopen(req).read().decode())
PY2
