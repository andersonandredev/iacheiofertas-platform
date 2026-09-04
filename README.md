# iacheiofertas-platform

Repo guarda-chuva da plataforma multi-nicho `iacheiofertas-*`. **Não tem código de
aplicação** — só o que amarra os serviços: `docker-compose`, contrato `/v1`
(OpenAPI), workflow de CI reutilizável e runbooks.

## Repos da plataforma (rodada 1)

| Repo | Papel | Vira container? |
|---|---|---|
| `iacheiofertas-core` | Integração loja/rede + endpoint `/v1` + portão de ACL + modo dry-run | ✅ `core` |
| `iacheiofertas-core-client` | SDK Python: client HTTP `/v1`, outbox, retry, config loader, log | ❌ (lib, importada pelos agentes) |
| `iacheiofertas-config` | `destinations/` `acl/` `targets/` — wiring de canal. **Dado, não código.** Nunca token (só `vault_ref`) | ❌ (lido por `core` e agentes; serviços seguem `main` e reportam o SHA em `config_rev`) |
| `iacheiofertas-agent-template` | Template dos agentes de nicho (`is_template=true`) | ❌ |
| `iacheiofertas-agent-glp` | Agente do nicho `achados_glp` (garimpo + roteamento lógico + dedup) | ✅ `agent-glp` |
| `iacheiofertas-agent-aquarismo` | Agente do nicho `aquarismo_marinho` | ✅ `agent-aquarismo` |
| `iacheiofertas-platform` | Este repo | ❌ |

**Fora de escopo da rodada 1:** `achados_de_grife_br` (pausado, 0 container),
sidecars `busca_html_*` (seguem no Mac + VPS, renomear pra `iacheiofertas-fetch-*`
num passe posterior), stack Evolution vive em `docker-compose.infra.yml` à parte.

## Layout

```
docker-compose.yml          core + agent-glp + agent-aquarismo (imagens do GHCR)
docker-compose.infra.yml    evolution-api + postgres + redis (+ manager, opcional)
.env.example                vars de nível de compose (tags de imagem, paths, config ref)
env/*.env.example           templates de segredo por serviço (real = SOPS ou no VPS)
openapi/v1.yaml             contrato canônico /v1 (healthz, enrich, publish)
.github/workflows/reusable-ship.yml   build → GHCR → SSH `compose pull && up -d`
docs/ARCHITECTURE.md        mapa dos repos e fluxo de dados
docs/RUNBOOK.md             setup, deploy, rollback, logs
docs/CUTOVER.md             migração de estado do stack legado pra v1
scripts/preflight.sh        checagens no VPS antes de subir
scripts/deploy.sh           deploy manual (espelha o job de deploy do CI)
```

## Começando

```sh
cp .env.example .env                 # ajuste tags / paths / CONFIG_REF
cp env/core.env.example env/core.env  # (idem pros agentes) — ou decripte via SOPS
./scripts/preflight.sh               # confere RAM/disco/docker/rede/env
docker network create iacheiofertas  # rede externa compartilhada pelos 2 composes
docker compose -p iacheiofertas-infra -f docker-compose.infra.yml up -d
docker compose up -d
```

Detalhes e rollback: [docs/RUNBOOK.md](docs/RUNBOOK.md).
