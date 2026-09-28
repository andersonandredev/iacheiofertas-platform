#!/usr/bin/env bash
# Alerta (push via ntfy) quando a instância do WhatsApp na Evolution sai de "open".
# Roda a cada 5 min pelo timer iacheiofertas-alerta-whatsapp. Motivação: em 27/09/2026 o
# WhatsApp desvinculou o aparelho às 20:12 e só percebemos na manhã seguinte, com todos os
# grupos parados.
#
# Avisa na queda, repete a cada ALERTA_REPETIR_MIN enquanto continuar fora e avisa quando
# volta. Lê do .env da plataforma: EVOLUTION_API_KEY, NTFY_TOPIC_ALERTAS e, opcional,
# EVOLUTION_INSTANCE_ALERTA (padrão reef-ofertas).
# Teste manual: scripts/alerta-whatsapp.sh --teste
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$DIR/.env"; set +a

INSTANCIA="${EVOLUTION_INSTANCE_ALERTA:-reef-ofertas}"
EVOLUTION="${EVOLUTION_LOCAL_URL:-http://127.0.0.1:8080}"
REPETIR_MIN="${ALERTA_REPETIR_MIN:-120}"
ESTADO_ARQ="${ALERTA_ESTADO_ARQ:-/var/lib/iacheiofertas/alerta-whatsapp.estado}"
: "${NTFY_TOPIC_ALERTAS:?NTFY_TOPIC_ALERTAS ausente no .env}"

avisar() {  # $1 título, $2 prioridade (1-5), $3 tags, $4 texto
  curl -fsS -o /dev/null -m 20 \
    -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
    -d "$4" "https://ntfy.sh/$NTFY_TOPIC_ALERTAS"
}

if [[ "${1:-}" == "--teste" ]]; then
  avisar "Teste de alerta" 3 "white_check_mark" "Se chegou, o alerta do WhatsApp do bot está funcionando."
  exit 0
fi

estado=$(curl -fsS -m 15 -H "apikey: $EVOLUTION_API_KEY" \
  "$EVOLUTION/instance/connectionState/$INSTANCIA" 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("instance",{}).get("state") or "desconhecido")' 2>/dev/null) \
  || estado="evolution_fora"

mkdir -p "$(dirname "$ESTADO_ARQ")"
anterior="open"; ultimo_aviso=0
[[ -f "$ESTADO_ARQ" ]] && read -r anterior ultimo_aviso < "$ESTADO_ARQ" || true
agora=$(date +%s)

if [[ "$estado" == "open" ]]; then
  if [[ "$anterior" != "open" ]]; then
    avisar "WhatsApp do bot voltou" 3 "white_check_mark" \
      "Instância $INSTANCIA conectada de novo. Os grupos voltam a receber na próxima janela."
  fi
  echo "open 0" > "$ESTADO_ARQ"
  exit 0
fi

if [[ "$anterior" == "open" || $(( agora - ultimo_aviso )) -ge $(( REPETIR_MIN * 60 )) ]]; then
  if [[ "$estado" == "evolution_fora" ]]; then
    msg="A Evolution API não respondeu em $EVOLUTION. Nenhum grupo de WhatsApp está recebendo ofertas."
  else
    msg="Instância $INSTANCIA está \"$estado\" (não conectada). Nenhum grupo de WhatsApp está recebendo ofertas. Pra religar: WhatsApp → Aparelhos conectados → escanear o QR (pedir ao Claude)."
  fi
  avisar "WhatsApp do bot DESCONECTADO" 5 "rotating_light" "$msg"
  ultimo_aviso=$agora
fi
echo "$estado $ultimo_aviso" > "$ESTADO_ARQ"
