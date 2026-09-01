#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker nao encontrado."
  exit 1
fi

if [ ! -f .env ]; then
  if command -v openssl >/dev/null 2>&1; then
    API_TOKEN="$(openssl rand -hex 32)"
    ADMIN_TOKEN="$(openssl rand -hex 32)"
  else
    API_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    ADMIN_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  fi

  cat > .env <<EOF
# e-GOV Login v8
EGOV_API_TOKEN=${API_TOKEN}
EGOV_ADMIN_TOKEN=${ADMIN_TOKEN}
EGOV_SESSION_TIMEOUT_SECONDS=180
EGOV_SEED_CPF=
EGOV_SEED_NAME="Aluno Teste"
EGOV_SEED_ROLE=aluno
EOF

  chmod 600 .env
fi

docker compose up -d --build

echo
echo "API e-GOV Login iniciada."
echo
echo "Porta publicada: 8089 -> 8088"
echo
echo "Teste local:"
echo "  curl http://127.0.0.1:8089/health"
