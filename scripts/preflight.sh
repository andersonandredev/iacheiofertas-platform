#!/usr/bin/env bash
# Checagens antes de subir a stack (rodar no VPS). Não altera nada.
set -uo pipefail

fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

echo "== docker =="
if command -v docker >/dev/null 2>&1; then ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"; else bad "docker não encontrado"; fi
if docker compose version >/dev/null 2>&1; then ok "compose $(docker compose version --short)"; else bad "docker compose v2 não encontrado"; fi

echo "== rede externa =="
if docker network inspect iacheiofertas >/dev/null 2>&1; then ok "rede 'iacheiofertas' existe"; else bad "falta: docker network create iacheiofertas"; fi

echo "== arquivos =="
[ -f .env ] && ok ".env presente" || bad ".env ausente (cp .env.example .env)"
for f in env/core.env env/agent-glp.env env/agent-aquarismo.env; do
  [ -f "$f" ] && ok "$f presente" || bad "$f ausente (cp $f.example $f  ou  sops -d $f.sops > $f)"
done

echo "== recursos (headroom da Fase 3 — decidir resize) =="
if command -v free >/dev/null 2>&1; then
  free -h | sed 's/^/  /'
  avail_mb=$(free -m | awk '/^Mem:/{print $7}')
  [ "${avail_mb:-0}" -ge 1024 ] && ok "RAM disponível ${avail_mb}MB" || warn "RAM disponível ${avail_mb}MB (<1GB) — considerar resize antes do cutover"
fi
echo "  disco:"; df -h / | sed 's/^/  /'

echo "== state dir =="
STATE_DIR=$(grep -E '^STATE_DIR=' .env 2>/dev/null | cut -d= -f2)
STATE_DIR=${STATE_DIR:-/opt/iacheiofertas/state}
for d in core agent-glp agent-aquarismo; do
  [ -d "$STATE_DIR/$d" ] && ok "$STATE_DIR/$d" || warn "$STATE_DIR/$d não existe (será criado no up; no cutover é onde entram os cache.db legados)"
done

echo
[ "$fail" -eq 0 ] && echo "preflight OK" || { echo "preflight com falhas"; exit 1; }
