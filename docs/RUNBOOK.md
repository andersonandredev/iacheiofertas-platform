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

# 5. preflight
./scripts/preflight.sh

# 6. infra e app
docker compose -p iacheiofertas-infra -f docker-compose.infra.yml up -d
docker compose up -d
```

Login no GHCR (imagens são privadas): `echo $GHCR_PAT | docker login ghcr.io -u andersonandredev --password-stdin`
(PAT com escopo `read:packages`).

## Deploy

Automático: push em `main` de qualquer repo de serviço → CI builda e faz `compose pull &&
up -d` só daquele serviço.

Manual (do Mac):
```sh
SSH_HOST=178.105.7.212 DEPLOY_DIR=/opt/iacheiofertas/platform ./scripts/deploy.sh core
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

## evolution-manager (painel web, opcional)

```sh
# pegar o nginx.conf corrigido do repo legado
cp ../../core_ofertas_br/evolution-manager-nginx.conf infra/evolution-manager-nginx.conf
docker compose -p iacheiofertas-infra -f docker-compose.infra.yml --profile manager up -d
```
