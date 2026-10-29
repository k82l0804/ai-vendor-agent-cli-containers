AGENTS ?= claude claude-proxy codex grok agy agy-proxy opencode kilo goose
A ?=
UID := $(shell id -u)
GID := $(shell id -g)
COMPOSE := docker compose

.PHONY: help base build rebuild up down restart ps logs shell smoke versions client-config prune clean

help:
	@echo "make build | rebuild | up | down | restart | ps | logs [A=x] | shell A=x | smoke [A=x] | versions | client-config | prune | clean"
	@echo "AGENTS='$(AGENTS)'"

base:
	docker build --build-arg UID=$(UID) --build-arg GID=$(GID) -t acp-base docker/base

build: base
	$(COMPOSE) build $(AGENTS)

# Fresh latest CLIs: no layer cache, newest node base.
rebuild:
	docker build --pull --no-cache --build-arg UID=$(UID) --build-arg GID=$(GID) -t acp-base docker/base
	$(COMPOSE) build --no-cache $(AGENTS)

PROXY_NET := openai-proxy_default

up:
	@docker network inspect $(PROXY_NET) >/dev/null 2>&1 || { echo "network $(PROXY_NET) not found: start the LiteLLM proxy first (cd ~/workarea/fox/openai-proxy && make up)"; exit 1; }
	$(COMPOSE) up -d $(AGENTS)

down:
	$(COMPOSE) down

# Recreate rather than restart, so changes to .env take effect.
restart:
	$(COMPOSE) up -d --force-recreate $(AGENTS)

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f $(A)

shell:
	@test -n "$(A)" || { echo "usage: make shell A=<agent>"; exit 2; }
	docker exec -it acp-$(A) bash

smoke:
	node scripts/acp-smoke.mjs $(or $(A),$(AGENTS))

versions:
	@for a in $(AGENTS); do printf '%-13s ' $$a; docker exec acp-$$a sh -c 'case $$ACP_AGENT in \
	  claude) echo "$$(claude --version) | $$(npm ls -g --depth=0 @agentclientprotocol/claude-agent-acp | grep -o "acp@.*")";; \
	  codex) npm ls -g --depth=0 @agentclientprotocol/codex-acp | grep -o "acp@.*";; \
	  grok) grok --version;; \
	  agy) basename "$$(cat /opt/agy/SOURCE)" .zip;; \
	  opencode) echo "opencode $$(opencode --version)";; \
	  kilo) echo "kilo $$(kilo --version 2>/dev/null | tail -1)";; \
	  goose) goose --version;; esac' 2>&1 | tail -1; done

# Each connection: a new container mounting the open VS Code folder (bin/acp-connect).
client-config:
	@echo '"acp.agents": {'
	@for a in $(AGENTS); do echo "  \"$$a (container)\": { \"command\": \"$(CURDIR)/bin/acp-connect\", \"args\": [\"$$a\"], \"env\": {} },"; done
	@echo '}'

# Per-connection containers left behind by a client that was killed instead of disconnecting.
prune:
	docker ps -aq --filter label=com.docker.compose.project=acp --filter label=com.docker.compose.oneoff=True | xargs -r docker rm -f

clean: prune
	$(COMPOSE) down --rmi all --remove-orphans
	-docker image rm acp-base
