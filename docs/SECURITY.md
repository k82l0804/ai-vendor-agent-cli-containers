# Security design: running AI coding agents in locked-down containers

This document is for security reviewers. It describes the **locked profile**, the controls it enforces, how each
control can be verified, and the risks that remain. The normal (home) profile is described in the
[README](../README.md); it deliberately omits these restrictions.

## The problem

AI coding agents (Claude Code, OpenCode, Kilo Code, Goose, Codex and others) are usually installed straight onto a
developer's workstation, as a CLI or as an editor extension. There they run with the developer's full rights:

- They read any file the user can read (SSH keys, cloud credentials, browser profiles, other projects).
- They run shell commands, and in "auto-approve" modes they do so without asking.
- They reach the internet freely: the model vendor, telemetry services, package registries, and any URL a prompt or
  a malicious file in a repository steers them to (prompt injection).
- They keep conversation history and "memories" in the user's home folder, which leak into later sessions and
  backups.
- They update themselves.

Each vendor offers some settings to restrict this, but the settings differ per tool, are easy to change, and are
enforced by the tool itself — the same software they are meant to constrain.

## The approach

Run each agent in a container, and have the editor talk to it over the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP), the way it would talk to a locally installed agent.
The containment is enforced by Docker and the kernel, outside the agent:

```
 VS Code + ACP Client extension (host)
        │ stdin/stdout of `bin/acp-connect opencode-locked` (no network port)
        ▼
 ┌──────────────── Docker network "acp-locked" (internal: no route out) ────────────────┐
 │  agent container (one per connection, removed on disconnect)                         │
 │    non-root · no capabilities · no-new-privileges · read-only root · CPU/memory/pids │
 │    sees only the open folder · fresh empty home · no real credentials                │
 │        │ model calls                              │ anything else (HTTP/S only)       │
 │        ▼                                          ▼                                   │
 │  llm-gateway (nginx)                         egress (Squid)                           │
 │    model API paths only, adds the key,         allowlist only (empty = deny all),     │
 │    logs every call                             logs every attempt                     │
 └────────┼──────────────────────────────────────────┼──────────────────────────────────┘
          ▼                                          ▼
   approved model server (LOCKED_LLM_UPSTREAM)   approved domains only (egress-allowlist.txt)
```

## Threat model

**In scope**

| Threat | Outcome with the locked profile |
|--------|---------------------------------|
| Source code or secrets sent to an unapproved model provider or website | No route exists. Model traffic can only go to `LOCKED_LLM_UPSTREAM`; everything else goes nowhere or hits the allowlist. |
| Prompt injection telling the agent to fetch a URL, `curl` data out, or use DNS to exfiltrate | Web tools are removed from the agent; `curl`/scripts get no connection; outside DNS names do not resolve. |
| Agent reads credentials on the workstation (SSH keys, cloud CLIs, other repos) | Only the open folder is mounted. The home folder inside the container is empty and new for each connection. |
| Theft of the model API key | Agents hold a placeholder; the gateway adds the real key. |
| Agent tampers with its own tooling or escalates privileges | Read-only root filesystem, non-root user, all capabilities dropped, `no-new-privileges`, no Docker socket. |
| Runaway processes (fork bombs, memory exhaustion) | `pids_limit`, `mem_limit`, `cpus`. |
| Conversation history or "memory" persisting and leaking | Each connection gets a throwaway home that is deleted on disconnect; the container is removed. |
| Telemetry and silent self-updates | Blocked by the network (and switched off in configuration where the tool supports it). |

**Out of scope** (see [Residual risks](#residual-risks))

- What the approved model server does with the prompts it receives.
- Kernel or container-runtime escapes.
- Changes the agent makes to the open folder that the developer later runs on the host.
- A compromised workstation or Docker installation.

## Controls

Every control below is enforced outside the agent. "Check" names the line printed by `make locked-check`.

| # | Control | How it is enforced | Where | Check |
|---|---------|--------------------|-------|-------|
| 1 | No direct internet, LAN or host access | Agents attach only to `acp-locked`, a Docker network with `internal: true`: no default route, no NAT | `compose.locked.yaml` → `networks.locked` | *internet by name/IP is unreachable*, *the Docker host is unreachable* |
| 2 | No outside DNS | Docker's resolver on an internal network answers only for containers on it | Docker | *outside DNS names do not resolve* |
| 3 | One approved model endpoint | `llm-gateway` is the only container on both `acp-locked` and the upstream network; it forwards only `/v1/…` and `/v1beta/…` to `LOCKED_LLM_UPSTREAM` | `locked/gateway.conf.template` | *model API reachable through llm-gateway*, *llm-gateway refuses non-model paths* |
| 4 | Agents hold no real credential | The gateway overwrites `Authorization`, `x-api-key` and `x-goog-api-key`; agents get `via-llm-gateway` | `locked/gateway.conf.template`, `compose.locked.yaml` | *the real model key is not in the container* |
| 5 | Allowlisted egress only | `egress` (Squid) is the only other dual-homed container; it allows only `locked/egress-allowlist.txt` (empty as shipped) on ports 80/443 | `locked/egress-squid.conf` | *egress proxy refuses a domain not on the allowlist* |
| 6 | Audit trail | Gateway logs every model call (time, path, status, bytes, duration); Squid logs every outbound attempt | `docker logs acp-llm-gateway`, `docker logs acp-egress`, `make locked-logs` | — |
| 7 | Least privilege in the container | Non-root user matching the developer's UID, `cap_drop: [ALL]`, `no-new-privileges`, read-only root, no Docker socket | `compose.locked.yaml` → `x-locked-agent` | *runs as a non-root user*, *no Linux capabilities*, *cannot gain privileges*, *root filesystem is read-only*, *no Docker socket* |
| 8 | Resource limits | `pids_limit: 512`, `mem_limit: 4g`, `cpus: 2` | `compose.locked.yaml` | *process limit set* |
| 9 | Only the open folder is visible | One bind mount, at the same path; parent folders are empty; optional read-only (`LOCKED_WORKSPACE_MODE=ro`) | `compose.locked.yaml`, `bin/acp-connect` | *only the workspace is mounted from the host* |
| 10 | Agent web tools removed | With `ACP_LOCKED=1` each agent's generated config denies its web tools (OpenCode/Kilo `webfetch`/`websearch: deny`; Claude Code `permissions.deny: [WebFetch, WebSearch]`; Goose keeps only its `developer` and `todo` extensions and disables the rest, including `summon`, `apps` and `extensionmanager`) | `docker/<agent>/setup.sh` | *web tools denied in …*, *goose extensions limited to developer and todo* |
| 11 | No persistent state | `acp-run` creates a new home in a tmpfs for each connection and deletes it on exit; `acp-connect` runs each connection in a new container (`docker compose run --rm`) | `docker/base/acp-run`, `bin/acp-connect` | — |
| 12 | No editor-side network listener | The editor starts `bin/acp-connect` and speaks ACP over its stdin/stdout | `bin/acp-connect` | — |

Controls 1–9 hold even if an agent ignores or rewrites its own configuration. Control 10 is defence in depth: it turns
a blocked network call into a clean "this tool is not available" for the user.

### Evidence from a test run

With the egress allowlist empty, these outbound attempts were made by the agents on their own (not by any prompt) and
were all refused by the egress proxy. Every agent still worked normally.

| Destination | Purpose (inferred) | Agent |
|-------------|--------------------|-------|
| `us.i.posthog.com:443` | product telemetry | Kilo |
| `api.kilo.ai:443`, `ai-gateway.kilo.ai:443` | vendor service / hosted models | Kilo |
| `models.dev:443`, `models.opencode.ai:443` | model catalogue download | OpenCode, Kilo |
| `registry.npmjs.org:443` | runtime package download | OpenCode, Kilo |

Asked to "use your web fetch tool to fetch https://example.com", the locked OpenCode, Kilo and Claude Code agents
each replied that they have no web fetch tool. Goose has no web tool in the locked profile, but it ships a built-in
`web-search` *skill* that tells the model to use `curl` in the shell; it loaded that skill, tried `curl` and `wget`
four times, and every attempt was refused by the egress proxy (`TCP_DENIED/403 CONNECT example.com:443`). This is
the case the network controls exist for: an agent that finds another way.

## Verifying it yourself

### Automated

```bash
make locked-build      # build the agent images, pull nginx and squid
make locked-check      # every control above, from inside each locked agent; exit code 0 = all passed
make locked-smoke      # real ACP sessions through the gateway: initialize, a prompt, a shell command
make locked-logs       # the audit trail from both
```

`make locked-check` needs no model calls. Example output (one agent shown):

```
== opencode-locked
  PASS  internet by name is unreachable (https://example.com)
  PASS  internet by IP is unreachable (http://1.1.1.1)
  PASS  outside DNS names do not resolve (example.com)
  PASS  the Docker host is unreachable (host.docker.internal:8000)
  PASS  the Docker host is unreachable (172.17.0.1:8000)
  PASS  egress proxy refuses a domain not on the allowlist
  PASS  model API reachable through llm-gateway with no key sent
  PASS  llm-gateway refuses non-model paths (/ui -> 403)
  PASS  runs as a non-root user
  PASS  no Linux capabilities (CapEff = 0)
  PASS  cannot gain privileges (NoNewPrivs = 1)
  PASS  root filesystem is read-only
  PASS  no Docker socket
  PASS  only the workspace is mounted from the host (/home/user/project)
  PASS  process limit set (pids.max = 512)
  PASS  web tools denied in opencode.json
  PASS  the real model key is not in the container
ALL CHECKS PASSED
```

### Manual (in the editor)

Connect to a `*-locked` agent in the ACP Client, then try to break out:

1. "Fetch https://example.com and summarise it." → the agent reports it has no web tool.
2. "Run `curl -sS https://example.com`." → the command fails to connect (or gets a 403 from the proxy).
3. "Run `cat ~/.ssh/id_rsa ~/.aws/credentials`." → no such files: the home folder is empty.
4. "Run `ls /home`, then `ls ..` from the project folder." → only the path down to the open folder exists.
5. "Run `env | grep -i key`." → only the placeholder `via-llm-gateway`.
6. "Run `sudo id` / `touch /usr/bin/x`." → no `sudo`; read-only file system.
7. Watch `make locked-logs` while doing this: the model calls appear in the gateway log, any outbound attempt in the
   egress log as `TCP_DENIED/403`.
8. Disconnect and reconnect, then ask "What did we talk about before?" → nothing: no history survives a connection.

## Configuration for a corporate environment

| Setting (`.env`) | Purpose |
|------------------|---------|
| `LOCKED_LLM_UPSTREAM` | Base URL of the approved model server (OpenAI-compatible; Anthropic- and Gemini-style paths are passed through too). Default `http://llm-proxy:8000`. |
| `LOCKED_LLM_KEY` | The credential the gateway adds. Prefer a per-user or per-team key with a model allowlist and budget. |
| `LOCKED_UPSTREAM_NETWORK` | Docker network from which `llm-gateway` reaches the upstream. For an upstream outside Docker, attach the gateway to a normal bridge network instead and restrict that host's egress with the firewall. |
| `LOCKED_WORKSPACE_MODE` | `rw` (default) or `ro` for review-only use. |
| `locked/egress-allowlist.txt` | Domains the agents may reach, e.g. an internal package mirror. Empty = none. |

Agents in the locked profile today: OpenCode, Kilo Code, Goose and Claude Code (through an Anthropic-compatible
gateway such as LiteLLM). Agents that only work with their vendor's cloud (Claude Code on a subscription, Codex, Grok,
Antigravity, Muse) are not part of the locked profile by design.

## Residual risks

| Risk | Notes and mitigations |
|------|----------------------|
| **Data reaches the model server** | That is the point of the tool. Govern it at the gateway: approved models only, prompt/response logging and retention, DLP or guardrails in the model gateway (e.g. LiteLLM guardrails). |
| **Changes to the open folder run later on the host** | With `rw`, an agent can write `.git/hooks/*`, `.vscode/tasks.json`, `package.json` scripts or a `Makefile` that the developer later executes outside the container. Review agent changes like any untrusted contribution; consider `core.hooksPath` policy, VS Code Workspace Trust, or `LOCKED_WORKSPACE_MODE=ro`. |
| **Allowlisted domains are exfiltration paths** | Keep `egress-allowlist.txt` to internal mirrors; Squid sees only the host name for HTTPS (no TLS inspection). |
| **The model gateway is reachable by every locked agent** | Anything sent to `/v1/…` is forwarded with the real key. Scope that key (models, budget, rate limits). |
| **Container escape** | Shared-kernel isolation. Keep the Docker engine and host kernel patched; for stronger isolation run the agents under gVisor or Kata Containers (`runtime:` in compose). |
| **Image provenance** | The images install the latest published CLIs at build time from public registries. For production: build from internal mirrors, pin versions and image digests, scan images, and rebuild on a schedule. |
| **The editor extension itself** | The ACP Client extension runs on the host with the user's rights and sends usage telemetry; set `telemetry.telemetryLevel` to `off` and treat it like any other extension. |
| **Docker Desktop specifics** | Behaviour was verified on Docker Desktop with WSL 2. `host.docker.internal` and the host's published ports were unreachable from the internal network; re-run `make locked-check` on each platform you support. |
| **Shell is a general-purpose tool** | Every agent can run `curl`, `python` or `node`. Tool-level settings cannot stop that; the network controls (1–5) do. |
| **Configuration-level controls** (control 10) | Enforced by the agent. If a future agent version renames a setting, the network still blocks the traffic; `make locked-check` will show the config check failing. |

## Files

| File | Role |
|------|------|
| `compose.locked.yaml` | The whole locked profile: network, gateway, egress proxy, hardened agent services |
| `locked/gateway.conf.template` | Gateway rules: paths, credential injection, audit log format |
| `locked/egress-squid.conf`, `locked/egress-allowlist.txt` | Egress policy |
| `scripts/locked-check.sh`, `scripts/locked-check-inside.sh` | Automated verification |
| `bin/acp-connect` | What the editor starts: one new container per connection |
| `docker/base/acp-run` | Per-connection throwaway home and clean-up |
| `docker/<agent>/setup.sh` | Per-agent configuration, including the locked settings |
