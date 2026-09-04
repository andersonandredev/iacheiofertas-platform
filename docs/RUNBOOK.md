# Runbook — iacheiofertas-platform

## Setup pela primeira vez (VPS)

```sh
# 1. clonar o platform no diretório de deploy
sudo mkdir -p /opt/iacheiofertas && sudo chown "$USER" /opt/iacheiofertas
git clone https://github.com/andersonandredev/iacheiofertas-platform /opt/iacheiofertas/platform
cd /opt/iacheiofertas/platform

# 2. config de compose
cp .env.example .env
$EDITOR .env                      # tags, CONFIG_REF, POSTGRES_*, EVOLUTION_API_KEY, sidecar URLs

# 3. segredos por serviço (uma das duas opções)
cp env/core.env.example env/core.env && $EDITOR env/core.env
#   ...ou:  sops -d env/core.env.sops > env/core.env
#   (idem agent-glp / agent-aquarismo)

# 4. rede + state dir
docker network create iacheiofertas
mkdir -p /opt/iacheiofertas/state/{core,agent-glp,agent-aquarismo}

# 5. deploy key do iacheiofertas-config (repo privado — core/agentes clonam de dentro
#    do container, ver app/config_repo.py em cada um). Gere UMA chave read-only:
mkdir -p /opt/iacheiofertas/secrets
ssh-keygen -t ed25519 -f /opt/iacheiofertas/secrets/iacheiofertas_config_deploy_key -N "" -C "vps-runtime-readonly"
gh repo deploy-key add /opt/iacheiofertas/secrets/iacheiofertas_config_deploy_key.pub \
  --repo andersonandredev/iacheiofertas-config --title "vps-runtime-readonly"
rm /opt/iacheiofertas/secrets/iacheiofertas_config_deploy_key.pub   # só a privada fica

# 6. preflight
./scripts/preflight.sh

# 7. infra e app
docker compose -p iacheiofertas-infra -f docker-compose.infra.yml up -d
docker compose up -d
```

Login no GHCR (imagens são privadas): `echo $GHCR_PAT | docker login ghcr.io -u andersonandredev --password-stdin`
(PAT com escopo `read:packages`).

**IMPORTANTE — logar como o usuário `deploy`, não só `root`:** o job de deploy do CI
(`reusable-ship.yml`) faz SSH como `SSH_USER` (=`deploy`) e roda `docker compose pull`
direto — não usa sudo pra root. Login feito só como root não vale pro CI (achado ao
vivo no cutover 2026-09-04: `docker compose pull` no deploy automático falhou com
`unauthorized` porque só `root` tinha `~/.docker/config.json` com credencial do GHCR;
`deploy` nunca tinha logado). Rodar como o próprio `deploy`:
`sudo -u deploy docker login ghcr.io -u andersonandredev --password-stdin` (senha via
stdin, nunca em texto/histórico).

## Deploy

Automático: push em `main` de qualquer repo de serviço → CI builda e faz `compose pull &&
up -d` só daquele serviço.

**Secrets do GitHub Actions** (configurados 2026-09-04, um conjunto por repo que faz
deploy — `iacheiofertas-core`, `-agent-glp`, `-agent-aquarismo`; `-agent-template` e
`-platform` não deployam nada, não precisam):
- `SSH_HOST` / `SSH_USER` (`deploy`, usuário dedicado no grupo `docker`, não root) /
  `SSH_KEY` / `DEPLOY_DIR` — usados pelo job `deploy` do `reusable-ship.yml`.
- `CORE_CLIENT_DEPLOY_KEY` — deploy key read-only do `iacheiofertas-core-client`,
  repassada ao build via BuildKit SSH forwarding (ver Dockerfile de cada consumidor:
  `RUN --mount=type=ssh` + `git config url.insteadOf` reescreve a URL https do
  `requirements.txt` pra ssh só durante o build).

Manual (do Mac):
```sh
SSH_HOST=<ip-do-vps> DEPLOY_DIR=/opt/iacheiofertas/platform ./scripts/deploy.sh core
```

Manual (no VPS):
```sh
cd /opt/iacheiofertas/platform && git pull --ff-only
docker compose pull core && docker compose up -d core
```

## Rollback

```sh
# fixa a tag do serviço num SHA bom e re-sobe
sed -i 's/^CORE_TAG=.*/CORE_TAG=<sha-bom>/' .env
docker compose up -d core
```
Evolution nunca sobe em duas stacks ao mesmo tempo — ver [CUTOVER.md](CUTOVER.md).

## Observação

```sh
docker compose ps
docker compose logs -f core
curl -s localhost:8000/v1/healthz | jq        # status + config_rev + dry_run
```

## Rede entre os dois composes

`docker-compose.yml` e `docker-compose.infra.yml` compartilham a rede externa
`iacheiofertas`. O `core` alcança `evolution-api` pelo nome de serviço porque o container
do infra registra esse alias na rede. Se `core` não resolver `evolution-api`:
`docker network inspect iacheiofertas` e confira que os dois containers estão listados.

## Dry-run

`CORE_DRY_RUN=true` no `.env` (ou `DRY_RUN=true` no `env/*.env` dos agentes) → todo
`/v1/publish` passa por ACL + cooldown/teto + log, mas o envio real (WhatsApp/Graph) vira
no-op. Usado na validação antes do cutover.

## Link curto próprio (`/r/{codigo}`)

`core` gera `{BASE_URL}/r/{codigo}` pro afiliado de ML/Amazon (ver `app/links.py` —
Shopee fica de fora, já tem link curto oficial da própria Shopee). Pra funcionar de
verdade, `BASE_URL` precisa ser um domínio público real roteado até `localhost:8000`
(o `core` só escuta em `127.0.0.1:8000`). Exemplo de bloco Caddy reaproveitando um
domínio que já serve outra coisa (`handle` por path, sem criar subdomínio novo):

```caddyfile
seu-dominio.example {
    handle /r/* {
        reverse_proxy localhost:8000
    }
    handle {
        reverse_proxy localhost:8001   # ou o que já servia esse domínio antes
    }
}
```

`systemctl reload caddy` depois de editar. `LINKS_CURTOS_DB_PATH` (default
`/app/state/links_curtos.db`, dentro do volume de estado) guarda o mapeamento
código→URL — sobrevive a redeploy, não sobrevive a apagar o volume de estado.

## evolution-manager (painel web, opcional)

```sh
# pegar o nginx.conf corrigido do repo legado
cp ../../core_ofertas_br/evolution-manager-nginx.conf infra/evolution-manager-nginx.conf
docker compose -p iacheiofertas-infra -f docker-compose.infra.yml --profile manager up -d
```
