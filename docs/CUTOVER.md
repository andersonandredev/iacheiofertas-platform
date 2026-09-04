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
  perfil do legado, não é bug. O ML sidecar (`busca_html_ml`) está sendo bloqueado pela
  parede `account-verification` do Mercado Livre em quase toda busca (409 Conflict,
  ~77/78 tentativas nas primeiras 24h de observação) — bloqueio pré-existente/externo,
  não introduzido pelo cutover, conhecido do usuário. Amazon segue funcionando normal.
  Dedup populando aos poucos via Amazon enquanto o bloqueio do ML persistir.

**INCIDENTE — 3 domínios públicos derrubados pelo passo 2 (achado e corrigido no mesmo
cutover, ~19:55-20:00):** `reefofertasbr.iacheiofertas.com.br`, `achadosglp.iacheiofertas.com.br`
e `curadoria.iacheiofertas.com.br` (Caddy) fazem `reverse_proxy localhost:8000` — porta
que era do `core_ofertas_app` legado (landing pages `/ofertas/<nicho>`, `/assets/...`,
portal `/curadoria`) e passou a ser do `core` v1 depois do `docker compose stop app` do
passo 2. **O core v1 não implementa nenhuma dessas rotas** (só `/v1/*`) — resultado:
404 nos 3 domínios, incluindo tráfego real de anúncio pago (query strings com
`utm_source=ig`/`fbclid` vistas nos logs do core v1 caindo em 404). Não estava no
escopo do cutover direto — essas rotas ficaram pro "cutover do core (últimos endpoints:
curadoria, conteúdo diário, bot de comentário)" da seção "Piloto gradual" abaixo, que só
seria feito depois de todo o resto validado; o corte direto pulou essa etapa sem migrar
essas rotas primeiro.

Correção aplicada (mantém as duas stacks sem colidir):
1. Porta do `app` no `docker-compose.yml` legado trocada de `8000:8000` pra
   `127.0.0.1:8001:8000` (só essa linha — backup em `docker-compose.yml.bak-cutover`).
2. `docker compose up -d app` sobe TAMBÉM `evolution-api`/`postgres`/`redis` legados
   por `depends_on` — `evolution-api` falhou ao subir por conflito de porta 8080 (a do
   v1 já estava nela) e isso **preveniu corretamente uma 2ª sessão WhatsApp**; mesmo
   assim `evolution-postgres`/`evolution-redis` legados subiram à toa — parados de novo
   (`docker compose stop evolution-postgres evolution-redis`).
3. `app` legado religado com `docker compose run --rm -d --no-deps -p 127.0.0.1:8001:8000
   -e CURADORIA_AGENDADOR=0 -e INSTAGRAM_FEED_ROTACAO_JOB=0 --name core_ofertas_app_readonly app`
   — **crítico**: o `app` sobe por padrão com workers internos (`curadoria-agendador`,
   checa fila a cada 30s; `instagram-rotacao`, gira bio do IG a cada 6h) que publicam de
   verdade — rodando em paralelo ao v1 isso duplicaria/conflitaria publicação. Só as
   rotas HTTP de leitura ficam ativas; nada de scheduler.
4. `/etc/caddy/Caddyfile` (backup em `/etc/caddy/Caddyfile.bak-cutover-<timestamp>`):
   os 3 blocos trocados de `reverse_proxy localhost:8000` pra `localhost:8001`,
   `systemctl reload caddy`. Confirmado 200/200/302 nos 3 domínios reais via HTTPS.

**Pendência real deixada por este atalho:** os 3 domínios hoje dependem de um container
legado (`core_ofertas_app_readonly`) rodando fora de qualquer `docker-compose.yml` do
`iacheiofertas-*` — sobrevive a um reboot só se alguém lembrar de resubir manualmente
(nada de `restart: always` nesse `docker compose run --rm`). Portar `/ofertas/<nicho>`,
`/assets/...` e `/curadoria` pro `core` v1 (ou um serviço `iacheiofertas-web` dedicado)
continua como trabalho futuro — até lá, esse container ad-hoc é o que sustenta os 3
domínios em produção.

### Teste de envio real (grupo admin) — 2 achados ao vivo, ambos corrigidos

Pedido do usuário: validar que o WhatsApp v1 consegue **enviar** de verdade (não só
ficar conectado) antes de virar `DRY_RUN=false` pra valer. Dois problemas apareceram:

1. **`EVOLUTION_INSTANCE_NAME` errado no `core.env` do VPS** (`iacheiofertas` em vez de
   `reef-ofertas`, o nome real da instância herdada) — todo envio real teria falhado com
   `404 Not Found` em `/message/sendText/<instance>`. `/v1/healthz` não pega esse tipo de
   erro (não testa envio). Corrigido no `core.env`, `core` recriado, confirmado via
   `curl .../instance/fetchInstances` (`name: "reef-ofertas"`, `connectionStatus: "open"`).
2. **Primeiro teste foi pro grupo errado.** Usei `EVOLUTION_GROUP_JID` do `.env` legado
   assumindo que era o grupo interno/admin — na verdade é o MESMO JID do grupo real
   **Reef Ofertas BR** (cliente de verdade, `aquarismo-marinho-principal`). Mensagem de
   teste chegou lá por engano; revogada (`chat/deleteMessageForEveryone`, aceita pelo
   Evolution) e o usuário também apagou manualmente. JID certo do grupo admin
   (**Admin IAcheiofertas.com.br**, `120363408747651331@g.us`) descoberto via
   `group/fetchAllGroups` e documentado em `iacheiofertas-config/README.md` pra nunca
   mais confundir. Reenviado com sucesso no grupo certo, confirmado pelo usuário.

**Lição:** `EVOLUTION_GROUP_JID` (sem sufixo de nicho) no `.env` legado é enganoso pelo
nome — não usar pra nada em v1. Único JID de teste seguro é o do Admin, documentado no
config repo.

Efeito colateral: o restart do `core` pra aplicar o fix #1 aconteceu no meio da rotina-a
do `agent-aquarismo` — as 25 categorias falharam com `connection refused` (core fora do
ar por alguns segundos durante o recreate). Não é bug, só efeito colateral do timing;
rotina-a pode ser re-rodada.

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
