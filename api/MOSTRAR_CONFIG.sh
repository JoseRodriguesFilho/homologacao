#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo ".env nao encontrado."
  exit 1
fi

grep -E '^(EGOV_|LAB_)' .env
