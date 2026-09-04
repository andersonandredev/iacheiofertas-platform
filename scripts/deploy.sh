#!/usr/bin/env bash
# Deploy manual — espelha o job `deploy` do reusable-ship.yml.
# Uso (do seu Mac):  ./scripts/deploy.sh [servico]
#   servico vazio = stack de app inteira.
# Espera as vars SSH_HOST, SSH_USER (default: deploy), DEPLOY_DIR no ambiente.
set -euo pipefail

SVC="${1:-}"
: "${SSH_HOST:?defina SSH_HOST}"
SSH_USER="${SSH_USER:-deploy}"
: "${DEPLOY_DIR:?defina DEPLOY_DIR (ex: /opt/iacheiofertas/platform)}"

echo ">> deploy ${SVC:-<stack completa>} em ${SSH_USER}@${SSH_HOST}:${DEPLOY_DIR}"
ssh "${SSH_USER}@${SSH_HOST}" bash -euo pipefail <<EOF
cd "${DEPLOY_DIR}"
git pull --ff-only || true
docker compose pull ${SVC}
docker compose up -d ${SVC}
docker compose ps
EOF
echo ">> ok"
