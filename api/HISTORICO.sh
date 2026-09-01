#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
set -a
source ./.env
set +a

ADMIN_TOKEN="${EGOV_ADMIN_TOKEN:-${LAB_ADMIN_TOKEN:-}}"
if [ -z "${ADMIN_TOKEN}" ]; then
  echo "Token administrativo nao encontrado no .env"
  exit 1
fi

curl -fsS \
  -H "X-Admin-Token: ${ADMIN_TOKEN}" \
  "http://127.0.0.1:8089/admin/sessions/history?limit=200"

echo
