# Cutover — stack legado → v1

O gargalo do cutover **não é código, é ESTADO de produção**. Um v1 zerado re-dispara
ofertas já enviadas, perde cooldown e perde a sessão de WhatsApp. Ordem importa.

## Estado a migrar

| Origem (legado) | Destino (v1) | Nota |
|---|---|---|
| `agente_ofertas_br/cache_achados_glp.db` | `${STATE_DIR}/agent-glp/cache.db` | copiar o arquivo **inteiro** — tem drift de coluna, não recriar do schema |
| `agente_ofertas_br/cache.db` (aquarismo) | `${STATE_DIR}/agent-aquarismo/cache.db` | idem |
| `core_ofertas_br/ingest_eventos.db` | `${STATE_DIR}/core/` | cooldown/teto/auditoria |
| `core_ofertas_br/links_curtos.json` | `${STATE_DIR}/core/` | link fixo da bio do Instagram |
| `core_ofertas_br/alertas_estado.json` | `${STATE_DIR}/core/` | cooldown de alerta de sessão |
| `core_ofertas_br/curadoria_midia/` | `${STATE_DIR}/core/curadoria_midia/` | mídia engatilhada na fila |
| catálogo manual ML (`catalogo_manual*.json`) | `${STATE_DIR}/core/` | mapa de catálogo ML |
| volume `evolution_instances` | volume `evolution_instances` (infra) | sessão WhatsApp pareada — ou re-parear via QR |
| tokens longos Meta | `env/core.env` (ou SOPS) | não expiram, mas precisam estar lá |

## Piloto: GLP primeiro

1. **Subir infra v1** (`docker-compose.infra.yml`) reaproveitando o volume
   `evolution_instances` do legado (mesmo nome de volume, ou `docker volume` clone).
   Só um Evolution no ar por vez.
2. **Parar só o agente GLP legado** (`docker compose stop agente-achados-glp` no
   `core_ofertas_br`). Deixar aquarismo e core legados rodando.
3. **Copiar o estado do GLP** (tabela acima) com o agente parado, pra não copiar SQLite
   sendo escrito.
4. **Subir `core` + `agent-glp` v1 em `CORE_DRY_RUN=true`**. Conferir `/v1/healthz`
   (`config_rev` certo), garimpo rodando, `/v1/publish` chegando e sendo logado como
   `dry_run` — sem envio real.
5. **Validar 1 ciclo** contra o canal de teste (Fase 2: 1 par staging FB+grupo+IG).
6. **Virar `CORE_DRY_RUN=false`** e observar a primeira publicação real do GLP.
7. **Desligar o GLP legado de vez.** Stack legado inteiro fica **parado, não apagado**,
   como rollback por 24-48h.
8. Repetir 2-7 pra **aquarismo**.
9. Cutover do `core` (últimos endpoints: curadoria, conteúdo diário, bot de comentário).

## Rollback

Parar o Evolution novo **antes** de subir o antigo — nunca os dois juntos (a 2ª
instância rouba a sessão → `conflict: replaced` → todo envio falha em todos os nichos).

```sh
docker compose -p iacheiofertas-infra -f docker-compose.infra.yml stop evolution-api
docker compose down                        # app v1
cd ../../core_ofertas_br && docker compose up -d   # legado de volta
```

## Antes da Fase 3

Rodar `scripts/preflight.sh` no VPS e olhar `free -h` — decidir resize do Hetzner antes
de ter as duas stacks coexistindo no cutover.
