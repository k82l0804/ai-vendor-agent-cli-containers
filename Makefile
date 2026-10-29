AGENTS ?= claude claude-proxy codex codex-proxy grok grok-proxy agy agy-proxy muse opencode kilo goose
# Locked profile (optional, see docs/SECURITY.md): agents that work with only a local model gateway.
LOCKED_AGENTS ?= opencode-locked kilo-locked goose-locked claude-locked codex-locked grok-locked agy-locked
A ?=
UID := $(shell id -u)
GID := $(shell id -g)
COMPOSE := docker compose
LOCKED_COMPOSE := docker compose -f compose.yaml -f compose.locked.yaml

.PHONY: help base build rebuild up down restart ps logs shell smoke versions client-config prune clean \
	locked-build locked-up locked-down locked-check locked-smoke locked-logs locked-client-config

help:
	@echo "make build | rebuild | up | down | restart | ps | logs [A=x] | shell A=x | smoke [A=x] | versions | client-config | prune | clean"
	@echo "locked profile: make locked-build | locked-up | locked-check | locked-smoke | locked-logs | locked-client-config | locked-down"
	@echo "AGENTS='$(AGENTS)'"
	@echo "LOCKED_AGENTS='$(LOCKED_AGENTS)'"

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
	  goose) goose --version;; \
	  muse) echo "$$(muse --version) | muse-acp + sdk $$(cd /opt/muse-acp && npm ls --depth=0 @muse-code/sdk | grep -o "sdk@.*")";; esac' 2>&1 | tail -1; done

# Each connection: a new container mounting the open VS Code folder (bin/acp-connect).
client-config:
	@echo '"acp.agents": {'
	@for a in $(AGENTS); do echo "  \"$$a (container)\": { \"command\": \"$(CURDIR)/bin/acp-connect\", \"args\": [\"$$a\"], \"env\": {} },"; done
	@echo '}'

# Per-connection containers left behind by a client that was killed instead of disconnecting.
# It also ends live sessions, so disconnect in VS Code first.
prune:
	@n=$$(docker ps -q --filter label=com.docker.compose.project=acp --filter label=com.docker.compose.oneoff=True | wc -l); [ $$n -eq 0 ] || echo "prune: removing $$n running connection container(s); any open session in VS Code ends"
	docker ps -aq --filter label=com.docker.compose.project=acp --filter label=com.docker.compose.oneoff=True | xargs -r docker rm -f

clean: prune locked-down
	$(COMPOSE) down --rmi all --remove-orphans
	-docker image rm acp-base

# ---- Locked profile -------------------------------------------------------------------------------------------
# Images for the locked agents (the same images as the normal profile) plus the gateway and egress proxy.
locked-build: base
	$(COMPOSE) build $(patsubst %-locked,%,$(LOCKED_AGENTS))
	$(LOCKED_COMPOSE) pull llm-gateway egress

# The gateway and egress proxy; agents start per connection (bin/acp-connect <name>-locked).
locked-up:
	@docker network inspect $${LOCKED_UPSTREAM_NETWORK:-$(PROXY_NET)} >/dev/null 2>&1 || { echo "network $${LOCKED_UPSTREAM_NETWORK:-$(PROXY_NET)} not found: start the model gateway first, or set LOCKED_UPSTREAM_NETWORK"; exit 1; }
	$(LOCKED_COMPOSE) up -d llm-gateway egress

locked-down:
	-$(LOCKED_COMPOSE) rm -sf llm-gateway egress
	-docker network rm acp-locked acp-egress-out 2>/dev/null

# Every control, checked from inside each locked agent container; no model calls. Exit status 0 = all passed.
locked-check: locked-up
	scripts/locked-check.sh $(LOCKED_AGENTS)

# The ACP smoke test through the locked agents (uses the model).
locked-smoke: locked-up
	ACP_SMOKE_VIA=connect node scripts/acp-smoke.mjs $(LOCKED_AGENTS)

# Audit trail: every model call (gateway) and every outbound attempt (egress proxy).
locked-logs:
	@echo "== llm-gateway (model calls)"; docker logs --tail 30 acp-llm-gateway 2>&1 | grep 'client='
	@echo "== egress (outbound attempts)"; docker logs --tail 30 acp-egress 2>&1 | grep -E 'TCP_'

locked-client-config:
	@echo '"acp.agents": {'
	@for a in $(LOCKED_AGENTS); do echo "  \"$$a\": { \"command\": \"$(CURDIR)/bin/acp-connect\", \"args\": [\"$$a\"], \"env\": {} },"; done
	@echo '}'
