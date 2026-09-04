# Arquitetura — plataforma iacheiofertas

## Por que a reestruturação

No stack legado (`core_ofertas_br` + `agente_ofertas_br`), o `core` é uma **biblioteca
compartilhada** importada pelos 3 agentes de nicho no mesmo repo. Ajustar um nicho obriga
a rebuildar/deployar tudo. A plataforma quebra isso em **N repos** que conversam por
**HTTP `/v1` versionado**.

## Fronteiras

```
┌─────────────────┐        POST /v1/enrich          ┌──────────────────────────┐
│  agent-glp      │ ─────  POST /v1/publish  ─────▶ │  core                    │
│  agent-aquarismo│        GET  /v1/healthz         │  - integração loja/rede  │
│  (garimpo +     │ ◀───────────────────────────────│  - portão de ACL         │
│   roteamento +  │                                 │  - resolve credencial    │
│   dedup local)  │                                 │  - modo dry-run          │
└─────────────────┘                                 └───────────┬──────────────┘
        │                                                       │
        │ lê targets (destination_id + canais)                  │ resolve credencial + ACL
        ▼                                                       ▼
┌────────────────────────────┐                    ┌──────────────────────────────┐
│ iacheiofertas-config (git) │                    │ vault (SOPS+age) + Evolution  │
│ destinations/ acl/ targets/│                    │ + Meta Graph + sidecars      │
│ dado, nunca token          │                    │ busca_html_*                 │
└────────────────────────────┘                    └──────────────────────────────┘
```

- **Agente** é dono do roteamento **lógico**: escolhe quais `targets` (lista de
  `destination_id` + canais) recebem a oferta, tirando de `iacheiofertas-config`.
- **Core** é o portão da **ACL** (valida cada `destination_id` contra o nicho) e o único
  que toca credencial (resolve do vault). Também aplica cooldown/teto por destino.
- **Dedup** fica no agente — 1 SQLite por nicho, estado próprio. A `idempotency_key` do
  `/v1/publish` sai daí.
- **config_rev**: core e agentes seguem o branch `main` de `iacheiofertas-config` e
  reportam o SHA carregado em `/v1/healthz`. Fixar num SHA só pra mudança arriscada.

## Contrato

Fonte de verdade: [`openapi/v1.yaml`](../openapi/v1.yaml).

| Rota | Uso |
|---|---|
| `GET /v1/healthz` | liveness + `config_rev` |
| `POST /v1/enrich` | URL de produto → normalizado (preço de/atual, drop, affiliate_url, image_url, flags). Sem LLM. |
| `POST /v1/publish` | `niche_id` + `offer` + `targets[]` + `idempotency_key` + `dry_run` |

Regra de evolução: **aditivo**. Campo novo é opcional; breaking change vira `/v2` ao lado.

## Deploy

- Cada repo de serviço tem um `ship.yml` de 6 linhas que chama
  [`reusable-ship.yml`](../.github/workflows/reusable-ship.yml) deste repo.
- CI: build → push `ghcr.io/andersonandredev/<repo>:main` (+ tag do SHA) → SSH no VPS
  `docker compose pull <svc> && docker compose up -d <svc>`.
- O `docker-compose.yml` **não tem `build:`** — só `image:` do GHCR.
- Tudo no mesmo VPS Hetzner. Sidecars `busca_html_*` seguem no Mac (túnel autossh
  reverso) e/ou como container no VPS — fora do escopo da rodada 1.

## Escopo da rodada 1

Só `achados_glp` + `aquarismo_marinho`. `achados_de_grife_br` está **pausado** (0
container) — `iacheiofertas-agent-grife` entra depois, a partir do template.
Piloto de validação e cutover: **GLP primeiro** (garimpo mais simples que o catálogo do
aquarismo).
