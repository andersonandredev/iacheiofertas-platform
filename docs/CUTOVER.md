# Cutover — stack legado → v1

O gargalo do cutover **não é código, é ESTADO de produção**. Um v1 zerado re-dispara
ofertas já enviadas, perde cooldown e perde a sessão de WhatsApp. Ordem importa.

## Cutover direto (executado 2026-09-04) — variante real, não o piloto gradual abaixo

Decisão do usuário: em vez do piloto gradual (GLP primeiro, dry-run, virar aos poucos —
seções abaixo, mantidas como referência pra um cutover futuro mais cauteloso), foi feito
um corte direto — parar o legado inteiro e subir o v1 inteiro — aproveitando uma janela
de baixo uso. RAM do VPS (3.7GiB, só ~850Mi livre com o legado rodando) não permitia
coexistência das 2 stacks por muito tempo de qualquer jeito.

**Preparação (sem tocar o legado rodando) feita antes do corte:**
- `/opt/iacheiofertas/platform` clonado, `/opt/iacheiofertas/state/{core,agent-glp,agent-aquarismo}`
  e `/opt/iacheiofertas/secrets/` criados.
- Deploy key read-only do `iacheiofertas-config` gerada NO PRÓPRIO VPS (nunca saiu de
  lá) em `/opt/iacheiofertas/secrets/iacheiofertas_config_deploy_key`.
- `env/core.env`, `env/agent-glp.env`, `env/agent-aquarismo.env` e `.env` populados com
  segredo real (mapeado dos `.env`/`.env.achados_glp` do legado — `DRY_RUN=true` /
  `CORE_DRY_RUN=true` ligados de propósito no primeiro boot).
- `docker-compose.infra.yml` ganhou `name:` configurável por env var
  (`EVOLUTION_INSTANCES_VOLUME`/`EVOLUTION_POSTGRES_VOLUME`/`EVOLUTION_REDIS_VOLUME`) —
  setado no `.env` pros nomes REAIS do legado (`docker volume ls` no VPS):
  `core_ofertas_br_evolution_instances`, `core_ofertas_br_postgres_data`,
  `core_ofertas_br_evolution_redis_data`. Assim o Evolution v1 herda a sessão WhatsApp
  pareada e o banco, sem re-parear via QR.
- Imagens (`core`, `agent-glp`, `agent-aquarismo`) buildadas e publicadas no GHCR via CI
  real (`gh workflow run`, verificado ponta a ponta), já pré-puxadas no VPS
  (`docker compose pull`).
- Os dois `docker compose config -q` (app + infra) validam com o env real. **Nada foi
  iniciado ainda** neste ponto — `docker compose ps` confirmado vazio nos dois projetos.

**O corte em si (não executado ainda na sessão que preparou isso — pendente de
confirmação explícita do usuário):**
1. Copiar o estado do legado (tabela "Estado a migrar" abaixo) com os containers
   legados ainda de pé, mas sabendo que pode haver um `.db` sendo escrito no instante da
   cópia — aceitável dado o corte é imediato em seguida (não fica dias com os dois no ar
   como o piloto gradual previa).
2. `cd /opt/reef-ofertas/core_ofertas_br && docker compose stop app agente agente-achados-glp evolution-api evolution-manager evolution-postgres evolution-redis`
   — **NÃO** `docker compose down` cru: isso pararia `busca-html-ml`/`busca-html-amazon`/
   `busca-html-google-shopping` TAMBÉM (mesmo compose file), e o core v1 depende deles
   rodando (`BUSCA_HTML_*_API_URL` aponta pro `172.17.0.1:812x` desses MESMOS
   containers — não fazem parte de nenhum compose do `iacheiofertas-*` ainda, ficam fora
   do escopo desta rodada, continuam geridos como sempre foram no legado). `stop`
   (não `down`) também preserva os volumes automaticamente, sem precisar do `name:`
   externo pra eles.
3. `cd /opt/iacheiofertas/platform && docker compose -p iacheiofertas-infra -f docker-compose.infra.yml up -d`
   (Evolution v1 sobe já com a sessão herdada).
4. `docker compose up -d` (core + os 2 agentes, em `DRY_RUN`/`CORE_DRY_RUN=true`).
5. Validar `/v1/healthz`, `/v1/publish` saindo como `dry_run`, garimpo populando o dedup
   (o discover já bate nos sidecars de verdade, que continuam de pé desde o passo 2).
6. Virar `DRY_RUN=false` nos 2 agentes e `CORE_DRY_RUN=false` no `.env`, `docker compose up -d` de novo.

Rollback: `docker compose down` no v1 (app + infra) e `docker compose up -d` de volta no
`core_ofertas_br` legado — os volumes do Evolution não foram copiados, só reapontados
(`name:` externo), então nenhum dos dois lados perde a sessão nesse meio tempo.

### Passo 5 executado — achados e correções ao vivo

- `docker exec` no `agent-glp` chamando `POST /rotina-b/run/08:30` contra o `cache.db`
  real migrado (719 linhas) estourou `TypeError: Candidata.__init__() got an unexpected
  keyword argument 'legenda'` — `dedup.py::listar_elegiveis` fazia `SELECT *` e o schema
  do banco legado tem colunas extras que a `Candidata` nova não declara. Corrigido nos
  3 repos (`agent-template`, `agent-glp`, `agent-aquarismo`) trocando por lista explícita
  de colunas; regressão coberta em teste; rebuildado via CI e redeployado — reconfirmado
  `200 {"status": "dry_run", ...}` com produto real nos dois agentes.
- No mesmo redeploy, `docker compose pull` do CI falhou com `unauthorized`: o usuário
  `deploy` (o que o job SSH do CI usa, via `SSH_USER`) nunca tinha feito `docker login`
  no GHCR — só `root` tinha essa credencial de uma sessão manual anterior. Corrigido
  logando o `deploy` também (ver docs/RUNBOOK.md, seção GHCR). Sem isso, **todo deploy
  automático via CI ficaria quebrado silenciosamente** nesse ponto, mesmo com a imagem
  publicada certa no GHCR.
- `POST /rotina-a/run` (garimpo) demora bastante contra os sidecars reais (timeouts de
  até 300s por keyword × múltiplas categorias/keywords) — comportamento esperado, mesmo
  perfil do legado, não é bug. Validação de que populou o dedup fica registrada abaixo
  quando terminar.

## Piloto gradual (plano original, não usado neste cutover — referência)

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
