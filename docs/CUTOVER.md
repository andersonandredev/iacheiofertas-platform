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

### GLP foi ao vivo pra valer — 2026-09-04 ~20:15 UTC (17:15 BRT)

Depois do teste no grupo admin confirmado OK, o usuário pediu pra testar o envio real
numa janela de verdade. Achado ao vivo o `CORE_DRY_RUN` (não `DRY_RUN` de
`env/core.env` — esse nem existe, é sobrescrito pelo `environment:` do
`docker-compose.yml`, que lê `CORE_DRY_RUN` do `.env` de topo) e o `DRY_RUN` do
`env/agent-glp.env` viraram `false`; `POST /rotina-b/run/08:30` manual no `agent-glp`
resultou em `status: partial`:
- **`whatsapp`: `sent`** — primeira publicação REAL da migração, foi pro grupo real
  "Achados GLP" (confirmado pelo usuário).
- **`instagram_story`: `error`** — `(#10) Application does not have permission for this
  action` (Graph API). Não é bug de código — reproduzido manualmente, token correto
  (197 chars, válido), payload idêntico ao do legado (`core_ofertas_br/app/instagram.py`,
  mesma assinatura/parâmetros). É estado atual do lado Meta — possivelmente relacionado à
  verificação de empresa/MEI no Meta Business feita pelo usuário nos mesmos dias
  (ver memória `reef_ofertas_mei_validacao_empresa`). Não bloqueia o WhatsApp — canais
  são independentes (`_status_agregado` em `publish.py`).

Usuário optou por **deixar `DRY_RUN=false` ligado** pro GLP (não reverter) — a partir
daqui o GLP está ao vivo de verdade em produção; a janela automática seguinte (17:35
BRT, scheduler do agente ativo por padrão) publica sozinha. Aquarismo continua em
`DRY_RUN=true`, não foi tocado.

**Pendência:** investigar a permissão `instagram_content_publish`/Stories do App/System
User no Meta Business Suite — fora do escopo de código.

**GLP pausado por completo (2026-09-04 ~23:19 UTC) até a restrição da Meta acabar
(2026-10-04).** Pedido do usuário: parar garimpo E envio no grupo do WhatsApp enquanto
o Instagram do GLP estiver bloqueado — não só o Instagram, o nicho inteiro. Aplicado via
`SCHEDULER_DISABLED=1` em `env/agent-glp.env` no VPS (não existia essa linha no arquivo
real, só no `.env.example` — precisou ser adicionada, não só editada) + recreate do
container. Isso desliga rotina_a (garimpo), rotina_b (WhatsApp/grupo) e conteudo_diario
(carrossel — evita gastar chamada de Anthropic pra um post que ia falhar no Instagram de
qualquer jeito) de uma vez só. Endpoints manuais (`/rotina-a/run` etc) continuam
funcionando, só o agendamento automático para. **Aquarismo não é afetado** (scheduler
próprio, container separado).

**Reverter em 2026-10-04 (ou quando a Meta liberar antes):** `SCHEDULER_DISABLED=0` (ou
apagar a linha) em `env/agent-glp.env` no VPS + `docker compose up -d agent-glp`, e
religar `instagram_story` (e talvez `instagram_feed`/`facebook_feed`) em
`iacheiofertas-config/targets/achados_glp.json`, que ficou só com `whatsapp` desde o
achado da restrição (ver seção acima).

### Aquarismo foi ao vivo pra valer — 2026-09-04 ~20:56 UTC (17:56 BRT)

Janela automática das 17:35 BRT confirmada rodando certo em dry_run (registro no
throttle às 20:35:00 UTC, `status: dry_run` nos 2 canais) — provou que o scheduler
(`rotina_b_<janela>` via `CronTrigger`, absoluto por horário, independe de restart do
container) está funcionando mesmo sem log HTTP (chamada interna, não via endpoint).
Usuário pediu pra ligar o envio real também no aquarismo: `DRY_RUN=false` em
`env/agent-aquarismo.env`, `agent-aquarismo` recriado. `core` já estava com
`CORE_DRY_RUN=false` desde o GLP. **Os dois nichos (GLP e aquarismo) estão ao vivo de
produção agora** — próxima janela do aquarismo (18:44 BRT) publica de verdade.

Monitor em background rodando a cada 20min reportando novas ofertas por loja
(`loja_origem`) em ambos os agentes, pra acompanhar o garimpo automático sem
intervenção manual.

### ML desbloqueado via sidecar existente no Mac (sem custo de proxy) — 2026-09-04 ~21:00 UTC

O bloqueio do ML (`account-verification`, 409) é só no IP do VPS Hetzner — descoberto
que o Mac do usuário já tinha infra pronta de antes (`~/Library/LaunchAgents/com.reef.sidecartunnel.plist`,
autossh com `KeepAlive`, túnel reverso `-R 172.17.0.1:18123:localhost:8123` etc pro
Hetzner) com 2 sidecars ML locais (`busca_html_ml` porta 8123→túnel 18123,
`busca_html_ml_2` porta 8126→túnel 18126) rodando havia dias, MAS não plugados em
lugar nenhum do v1. Testado: busca real via `http://172.17.0.1:18123/busca` (do VPS,
pelo túnel) retorna resultados de verdade da lista do ML — **IP do Mac não está
bloqueado**, confirma que o bloqueio é por reputação de IP datacenter, não por
fingerprint do Selenium.

Fix: `.env` de topo do VPS —
`BUSCA_HTML_ML_API_URL=http://172.17.0.1:18123` (era `http://172.17.0.1:8123`, o
sidecar bloqueado do próprio VPS) e `BUSCA_HTML_ML_2_API_URL=http://172.17.0.1:8123`
(o antigo vira secundário — `core`/`mercadolivre.py::_sidecars_ml()` já tenta os dois
em sequência por keyword, sem mudança de código, só de env). `core` recreated,
testado (`buscar_ofertas_por_palavra_chave` retornando resultados reais). Beneficia
GLP e aquarismo juntos (config do `core`, não por nicho).

**Fragilidade aceita:** garimpo de ML agora depende do Mac estar ligado, conectado e
com o túnel de pé (`launchctl list com.reef.sidecartunnel`, log em
`~/Library/Logs/reef-sidecartunnel.log`) — se cair, falha silenciosa (core trata
timeout/erro de rede como sidecar "fora do ar", retorna `[]`, não quebra nada, só
volta a ficar sem resultado de ML até o Mac voltar). Considerar contratar proxy
residencial (Webshare/IPRoyal, mais barato pra testar) se essa dependência incomodar
no longo prazo.

### Feed do Instagram/Facebook + rotação de 7 dias portados pro v1 — 2026-09-04 ~22:12 UTC

Pedido do usuário: voltar a regra do legado (memória
reef_ofertas_meta_instagram_integration) de publicar cada oferta também no feed
(IG imagem única + espelho na Página FB) e apagar via API depois de 7 dias, virando
catálogo rolante. Implementado no `core` (`app/feed_posts.py` registro,
`app/feed_rotacao.py` worker APScheduler a cada `FEED_ROTACAO_INTERVALO_HORAS` — ver
commit `d04a922`), ligado só pro **aquarismo** (`targets/aquarismo_marinho.json` +
`instagram_feed`/`facebook_feed`) — GLP fica de fora enquanto durar a restrição de
conta da Meta (até 2026-10-04, ver seção acima). Link curto próprio do ML (`/r/{codigo}`)
também portado antes disso (commit `9130366`) — Amazon fica com o link oficial direto
por decisão do usuário (já curto o bastante).

Validado ao vivo, ponta a ponta, contra a API real: `POST /v1/publish` com
`instagram_feed`+`facebook_feed` → `sent` nos dois, registrado em `feed_posts.db`;
posts backdatados pra 8 dias; `feed_rotacao.rodar_rotacao()` chamado manualmente →
`{"apagados": 2, "falhas": 0}`; confirmado por `GET` direto na Graph API que os 2
posts de teste realmente sumiram do Instagram/Facebook. Sem custo de proxy ou infra
nova — só o worker já embutido no `core`.

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
