# AGENTS.md

Runs AI coding-agent CLIs (Claude Code, Codex, Grok, Antigravity/agy, Muse, opencode, Kilo, Goose) in containers, and
connects them to an ACP client (the VS Code "ACP Client" extension) over stdio. Each connection is a fresh container
that mounts only the open folder. The README is the user guide, `docs/SPEC.md` holds the design and per-agent
findings, and `docs/SECURITY.md` covers the locked profile.

## Layout

| Path | What it is |
|---|---|
| `bin/acp-compose` | **The only place that picks the engine.** It runs `docker compose` or `podman compose` with this project's compose files, and sets `ACP_USERNS=keep-id` under Podman. `--engine` prints `docker` or `podman`. |
| `bin/acp-connect` | What the editor starts: one `compose run --rm` per connection, mounting the current folder at the same path. |
| `compose.yaml` | One service per agent (normal profile). `x-agent` holds the shared settings. |
| `compose.locked.yaml` | Locked profile: internal network, `llm-gateway` (nginx, adds the model key), `egress` (squid, allowlist), hardened agents. |
| `docker/base/` | The base image: the `agent` user with your UID, `acp-run` (a fresh home per connection), and `acp-shim`. |
| `docker/<agent>/` | `Dockerfile` and `setup.sh` (that agent's config, credentials and locked settings, sourced by `acp-run`). |
| `locked/` | The gateway template, the squid config and the egress allowlist. |
| `scripts/acp-smoke.mjs` | ACP smoke test (`make smoke`, `make locked-smoke`). |
| `scripts/locked-check*.sh` | Checks the locked profile's controls from inside each locked container (`make locked-check`). |
| `docs/podman-install.md` | Host setup for rootless Podman (OL8 / WSL 2) and what differs under Podman. |

## Rules

- **Must work with Docker and with rootless Podman, on WSL 2 and on a normal Linux host (including SELinux
  enforcing).** Docker Desktop on Ubuntu/WSL is the reference setup and must not regress.
  - Never call `docker` or `docker compose` directly in the Makefile or scripts. Use `$(ENGINE)` / `$(COMPOSE)` in
    the Makefile, and `bin/acp-compose` (or `bin/acp-compose --engine`) in scripts.
  - Every Podman-only setting must be a no-op under Docker. Examples: `userns_mode: ${ACP_USERNS:-}`, and `:z` on
    bind mounts.
  - Use fully qualified image names (`docker.io/library/…`).
  - In the locked profile, run per-connection containers with `--no-deps` after starting `llm-gateway`/`egress`
    once. Compose with Podman 4.x recreates running containers on every `up`/`run` (see `docs/podman-install.md`).
- **Secrets:** never read, print or log the values in `.env` or in the host login files (`~/.codex`, `~/.grok`,
  `~/.gemini`, `~/.config/muse`, `~/.claude`). Only check that they're present and non-empty. `scripts/locked-check.sh`
  reads the gateway key only to prove that it never reaches a container; don't print it.
- **The ACP stdout is the protocol.** Anything `bin/acp-connect` or `acp-run` prints must go to stderr.
- Credentials come in read-only and are copied into each connection's fresh home. They are never written back.
  Claude uses `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) in `.env`.
- The model proxy is a separate project (`~/workarea/openai-proxy`, network `openai-proxy_default`).
- Shell: `bash`, `set -euo pipefail`, ShellCheck-clean.

## Checking changes

```bash
make build                     # all images (make rebuild: no cache, newest CLIs)
make up && make smoke A=claude # one agent end to end (uses the model)
make smoke                     # every agent; subscription agents need their host login (see .env.example)
make locked-check              # every locked-profile control, no model calls: must print ALL CHECKS PASSED
make locked-smoke              # the locked agents end to end
```

When you change something engine-specific, run `make locked-check` and a smoke test under **both** Docker and Podman.
`ACP_ENGINE=docker|podman` forces one on a host that has both.
