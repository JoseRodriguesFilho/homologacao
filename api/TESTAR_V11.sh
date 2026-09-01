#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
set -a
source ./.env
set +a
TOKEN="${EGOV_API_TOKEN:-${LAB_API_TOKEN:-}}"
[ -n "$TOKEN" ] || { echo "EGOV_API_TOKEN nao encontrado"; exit 1; }

CPF="${1:-52998224725}"
MATRICULA="${2:-12345678}"

post() {
  local body="$1"
  curl -fsS -X POST http://127.0.0.1:8089/auth/preview \
    -H 'Content-Type: application/json' -H "X-eGOV-Token: ${TOKEN}" -d "$body"
  echo
}

echo "== Outros / CPF =="
post "{\"identifier\":\"$CPF\",\"identifier_type\":\"cpf\",\"institution\":\"outros\",\"computer\":\"LAB-HOMOLOG\",\"target\":\"student\"}"

echo "== UNIVESP / Matricula =="
post "{\"identifier\":\"$MATRICULA\",\"identifier_type\":\"matricula\",\"institution\":\"univesp\",\"computer\":\"LAB-HOMOLOG\",\"target\":\"student\"}"
