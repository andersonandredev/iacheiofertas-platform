.PHONY: help preflight up down infra-up infra-down logs ps pull health lint

COMPOSE      := docker compose
COMPOSE_INFRA := docker compose -p iacheiofertas-infra -f docker-compose.infra.yml

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

preflight: ## checagens no VPS antes de subir
	./scripts/preflight.sh

infra-up: ## sobe Evolution + Postgres + Redis
	docker network create iacheiofertas 2>/dev/null || true
	$(COMPOSE_INFRA) up -d

infra-down: ## para a stack de infra
	$(COMPOSE_INFRA) down

up: ## sobe core + agentes (pull primeiro)
	$(COMPOSE) pull
	$(COMPOSE) up -d

down: ## para core + agentes
	$(COMPOSE) down

pull: ## atualiza as imagens do GHCR
	$(COMPOSE) pull

ps: ## estado dos containers (app + infra)
	$(COMPOSE) ps
	$(COMPOSE_INFRA) ps

logs: ## logs do core (SVC=agent-glp pra outro)
	$(COMPOSE) logs -f $(or $(SVC),core)

health: ## /v1/healthz do core
	curl -s localhost:8000/v1/healthz | (command -v jq >/dev/null && jq || cat)

lint: ## valida os compose files
	$(COMPOSE) config -q && $(COMPOSE_INFRA) config -q && echo "compose ok"
