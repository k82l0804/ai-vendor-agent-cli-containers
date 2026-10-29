# ai-vendor-agent-cli-containers — Spec & Plan

Status: draft, 2026-10-28. All decisions below were made with the owner; nothing is open except the Phase 0 probes.

## First use case

You give each agent, by hand, the same short prompt about `~/workarea/tmp/spec.md` and compare the plans they write.
Nothing in this project is specific to that.

## Goal

Run each AI coding-agent CLI in its own Docker container, each speaking ACP (Agent Client Protocol), so a VS Code
ACP client extension can drive it. Every connection starts as if the CLI were freshly installed: no prior
conversations, memories, project history or user config. `docker compose` brings them up; a `Makefile` wraps the
common Docker chores.

## Feasibility (yes)

- ACP is JSON-RPC 2.0 over **stdio**. An ACP client spawns a command and talks over its stdin/stdout. That command can
  be `docker exec -i <container> …`, so no network ports or bridges are needed.
- `~/workarea/src/grok-build-vscode` already drives grok, codex, claude, muse and agy this way (as child processes, not
  in containers). How each one starts there is reused below.
- Freshness does not depend on vendor flags: every connection gets a throwaway `$HOME`. Vendor flags that suppress
  memory, history or telemetry go on top of that.

## Architecture

```
VS Code ACP client
   │ spawns:  docker exec -i acp-claude acp-run
   ▼
container acp-claude (long-running, `sleep infinity`, tini as PID 1)
   acp-run (per connection):
     1. HOME=$(mktemp -d /tmp/acp-home.XXXX)        ← /tmp is tmpfs
     2. copy login files from /creds (read-only mount) into $HOME
     3. write minimal vendor config: yolo + memory/history/telemetry off
     4. run the agent's ACP command in the workspace, stdio passed straight through
     5. on stdin EOF / exit / signal: kill the agent's process group, rm -rf $HOME
```

- **One container per agent**, kept up by compose. Each `docker exec` is one connection with its own fresh home, so
  connections don't share state and you can run several at once.
- **Images**: shared `base` image (Debian slim, Node 22, git, ripgrep, curl, tini, `acp-run`, non-root user `agent`
  whose UID/GID match the host user). Each agent gets a thin layer on top of `base` that installs **the latest** CLI
  (and its adapter) at build time. `make rebuild` builds with `--no-cache --pull` to pick up new versions.
- **Workspace**: `WORKSPACE` (default `/home/k82l0804/workarea/tmp`) is bind-mounted read-write **at the same absolute
  path** inside every container, so the `cwd` the client sends in `session/new` is valid as-is. Files the agents
  create belong to your user (the in-container UID matches yours). `acp-run` only passes stdio through and never
  reads the messages, so the client's working directory must point inside `WORKSPACE` (see the client section).
- **Auth**:
  - **claude**: long-lived `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) in `.env`. Nothing is copied and
    nothing refreshes.
  - **codex, grok, agy**: each CLI's host login files are mounted **read-only** into `/creds/<agent>/` and
    copied into each connection's fresh home. They are never written back.
  - **opencode, kilo, goose**: the local LiteLLM proxy (`~/workarea/fox/openai-proxy`, container `llm-proxy`). Our services
    join its external network `openai-proxy_default` and call `http://llm-proxy:8000/v1`. The key goes in our `.env`
    as `LITELLM_MASTER_KEY`, the same name the proxy project uses. The model comes from
    `OPENCODE_MODEL` / `KILO_MODEL` / `GOOSE_MODEL` (any `model_name` in the proxy's `litellm_config.yaml`, e.g.
    `or-claude-sonnet-5.5`, `grok-4.7`, `gemini-3.1-pro`).
- **Permissions**: auto-approve (yolo) everywhere. The container limits what an agent can damage; only `WORKSPACE`
  is exposed.

## Connecting: the open VS Code folder (current setup)

The ACP Client starts the agent command in the open VS Code folder and sends that folder as the session `cwd`. It
ignores `acp.defaultWorkingDirectory` when a folder is open. `bin/acp-connect <service>` uses this: it runs
`docker compose run --rm` for that service with `WORKSPACE` set to the folder it was started in. So each connection gets:

- a **new container** that mounts only that folder, at the same path, and is removed on disconnect (`make prune` removes
  any left behind by a killed client);
- the same login mounts, environment and proxy network as the compose service;
- no access to the folders above it (they are empty in the container), so no outside `AGENTS.md`/`CLAUDE.md`/config.

With no folder open the client uses its own cwd (home or `/`). `acp-connect` never mounts those; it falls back to
`~/workarea/tmp`. Folders under `/tmp` are not supported: they collide with the container's own `/tmp` (Claude Code
refuses a `/tmp/claude-<uid>` it doesn't own).

The long-running containers (`make up`, `docker exec -i acp-<service> acp-run`) still work, with the fixed
`WORKSPACE`. In that mode `acp-shim` replaces a `cwd` that doesn't exist in the container with `WORKSPACE`.

`acp-shim` (base image) sits between the client and every agent. It changes only that `cwd` and, with
`ACP_INITIAL_MODE` set, sends `session/set_mode` right after a session is created: `yolo` for agy, which has no
other way to start in it; `agent-full-access` for codex, whose default `agent` mode needs bubblewrap and fails in Docker.

## Per-agent matrix

The flags and config keys still need confirming against the installed versions in Phase 0. "Fresh home" always applies.

| Agent | Install (latest) | ACP command | Login files copied in | Yolo | Extra freshness |
|-------|------------------|-------------|------------------------|------|-----------------|
| claude, claude-proxy | `@anthropic-ai/claude-code` + `@agentclientprotocol/claude-agent-acp` (npm), `CLAUDE_CODE_EXECUTABLE=/usr/local/bin/claude` | `claude-agent-acp` | `claude`: `CLAUDE_CODE_OAUTH_TOKEN` env. `claude-proxy`: `ANTHROPIC_BASE_URL=http://llm-proxy:8000`, `ANTHROPIC_AUTH_TOKEN=$LITELLM_MASTER_KEY`, every model variable = `CLAUDE_PROXY_MODEL`. Both: a minimal `.claude.json` with onboarding marked done | settings `permissions.defaultMode: bypassPermissions` (needs a non-root user) | auto-memory off; telemetry and non-essential traffic off via env |
| codex | `@openai/codex` + `@agentclientprotocol/codex-acp` (npm) | `codex-acp` | `.codex/auth.json` | config `approval_policy="never"`, `sandbox_mode="danger-full-access"`, plus session mode `agent-full-access` via `acp-shim` (codex's bubblewrap sandbox doesn't work inside Docker) | `history.persistence="none"`, memories off |
| grok | xAI installer | `grok agent --no-leader stdio` | `.grok/auth.json` | config `[ui] permission_mode = "always-approve"` (confirmed) | no leader process; fresh `GROK_HOME` |
| opencode | opencode installer | `opencode acp` | none: generated `opencode.json` with an OpenAI-compatible provider pointing at `llm-proxy`, model `OPENCODE_MODEL` | config `permission: allow` | fresh data dir |
| kilo | `@kilocode/cli` (npm; a fork of opencode) | `kilo acp --pure` | none: generated `kilo.jsonc` with an `@ai-sdk/openai-compatible` provider pointing at `llm-proxy` (same as the host's `local` provider), model `KILO_MODEL` | config `permission: allow` | fresh data dir; `--pure` loads no outside plugins |
| goose | goose installer | `goose acp` | none: `GOOSE_PROVIDER=openai`, `OPENAI_HOST=http://llm-proxy:8000`, `OPENAI_API_KEY=$LITELLM_MASTER_KEY`, `GOOSE_MODEL`, keyring disabled | `GOOSE_MODE=auto` | fresh session DB |
| agy, agy-proxy | Google `agy-acp-server`, latest from the ACP registry (SHA-256 checked; ~1 GB unpacked) | `agy_acp_server.par --uid=` | `agy`: `~/.gemini/antigravity-acp/acp_token.json` + `settings.json` `auth.type=oauth-personal`. `agy-proxy`: `auth.type=gemini-api-key`, `GEMINI_API_KEY=$LITELLM_MASTER_KEY`, `GOOGLE_GEMINI_BASE_URL=http://llm-proxy:8000` | new sessions always start in `default`, and no flag, env var or setting changes that (the server takes only `--debug`/`--notices`; `--dangerously-skip-permissions` belongs to the `agy` CLI). `acp-mode-shim` sends `session/set_mode yolo` after each `session/new` (`ACP_INITIAL_MODE=yolo`) | experimental; biggest image |

| muse | Meta's installer (launcher + binary in `/opt/muse`, `MUSE_NO_AUTO_UPDATE=1`) + our adapter `docker/muse/muse-acp.mjs` on `@muse-code/sdk` (MIT, same version as the CLI) | `node /opt/muse-acp/muse-acp.mjs`, which runs `muse serve --provider meta --disable-sandbox --trust-workspace --no-session-log --contributor-mode off` | `~/.config/muse/auth.json` | sessions start in approval mode `allowAll`; any approval Muse still asks for gets its first allowing choice | `--no-session-log` (memory-only sessions); model from `MUSE_MODEL`, else Muse's default |

Muse has no ACP mode, only its own MSP. grok-build-vscode has an adapter, but it is FSL-licensed (no competing use),
so this repo has its own minimal one: hand-written ACP JSON-RPC on one side, Meta's SDK on the other. It covers
`initialize`, `session/new`, `session/prompt` (text, reasoning and tool calls streamed), `session/cancel` (`turn/cancel`) and
`session/set_config_option`: Model and Effort pickers from Muse's `model/list` catalog (`session/setModel`,
`session/setReasoningEffort`). On this account the catalog is muse-wonder-1.0 (default, effort `max`),
muse-wonder-full-1.0, muse-spark-1.3 and muse-spark-1.2; effort is Muse's eight tiers `none`…`ultra`, or the tiers a
model's row lists. Not supported: loading or listing past sessions, images, approval-mode switching.

Left out: **copilot**, **gemini** (dropped, see Phase 0 results).

### Models: vendor or local proxy

| CLI | Can use the LiteLLM proxy? | How |
|-----|----------------------------|-----|
| opencode, kilo, goose | yes (OpenAI format) | the only option configured here |
| grok | yes (OpenAI format) | `[model.<name>]` with `base_url` and `api_backend = "chat_completions"`/`responses`/`messages` (grok's custom-models guide) |
| codex | yes (OpenAI Responses) | `model_providers` with a `base_url` (not tested) |
| claude | yes, through LiteLLM's Anthropic-format `/v1/messages` | the `claude-proxy` service (works; no Claude-named alias needed because every model variable is set to the proxy model) |
| agy | yes, through the Gemini-format route | as in `~/workarea/fox/openai-proxy/scripts/agy-proxy.sh`: `modelProvider: "gemini"` in `antigravity-cli/settings.json`, `GEMINI_API_KEY=$LITELLM_MASTER_KEY`, `GOOGLE_GEMINI_BASE_URL=<proxy>`. agy only asks for its own model names, so LiteLLM's `model_group_alias` decides the real model (`gemini-3.8-flash` → `nemotron-3-ultra` today), and `agy_callbacks.py` fixes agy's tool results. `agy_acp_server` respects `GEMINI_API_KEY` + `GOOGLE_GEMINI_BASE_URL` with `auth.type=gemini-api-key` (the `agy-proxy` service; works: Google would reject the LiteLLM key, so a reply means it went through the proxy) |
| muse | no | — |

## Repository layout

```
docker/base/Dockerfile          shared base
docker/<agent>/Dockerfile       FROM base; installs the CLI + adapter
docker/<agent>/setup.sh         writes per-connection config (yolo, memory off) into $HOME
bin/acp-run                     per-connection wrapper (generic; sources setup.sh)
compose.yaml                    one service per agent; profiles so you can start a subset
.env.example                    WORKSPACE, UID/GID, host cred paths, AGENTS=...
Makefile
scripts/acp-smoke.mjs           initialize + session/new probe through docker exec
docs/SPEC.md                    this file
docs/vscode-client.md           client config snippets
```

## Makefile targets

`build` · `rebuild` (no cache, latest CLIs) · `up` · `down` · `restart` · `ps` · `logs [A=claude]` ·
`shell A=claude` (bash in the container) · `smoke [A=claude]` (ACP handshake test) · `versions` (print each CLI
version) · `clean` (down, remove images, prune stray homes) · `client-config` (print the VS Code snippet per agent).
`AGENTS=claude,codex` limits which services run.

## VS Code client configuration — "ACP Client" by Jun Han (`formulahendry.acp-client`)

The extension reads `acp.agents`: each key is an agent name, each value is `{ command, args, env }`. It talks to the
agent over stdio. `make client-config` prints this block for the agents you've enabled:

```jsonc
"acp.defaultWorkingDirectory": "/home/k82l0804/workarea/tmp",
"acp.agents": {
  "claude (container)":   { "command": "<repo>/bin/acp-connect", "args": ["claude"] },
  "codex (container)":    { "command": "<repo>/bin/acp-connect", "args": ["codex"] },
  "grok (container)":     { "command": "<repo>/bin/acp-connect", "args": ["grok"] },
  "opencode (container)": { "command": "<repo>/bin/acp-connect", "args": ["opencode"] },
  "goose (container)":    { "command": "<repo>/bin/acp-connect", "args": ["goose"] },
  "agy (container)":      { "command": "<repo>/bin/acp-connect", "args": ["agy"] }
  // … one entry per service, including claude-proxy, agy-proxy and kilo
}
```

- Whatever folder is open in VS Code is the agent's folder (see "Connecting"). `acp.defaultWorkingDirectory` only
  matters when no folder is open.
- VS Code merges `acp.agents` with the extension's built-in `npx` agents, so they stay listed. Those run on the host
  with your real home folder and history; use the "(container)" entries.
- Never add `-t` to a `docker exec`/`compose run` agent command: a TTY corrupts the JSON-RPC stream.
- Turn on `acp.logTraffic` while debugging; the frames appear in the "ACP Traffic" output channel.
- The extension must run where `docker` works. In a Remote-WSL window that's the WSL side, which is what we want.

## Usage

Prompting is manual. Pick an agent in the ACP Client and chat with it. This project only provides the containers.

## Plan

**Phase 0 — probes (de-risk, ~1 session).** For each agent: build its image, then run `scripts/acp-smoke.mjs` through
`docker exec`. Pass means `initialize` → `session/new` → one prompt ("reply OK") → clean exit, with the throwaway home
gone afterwards. Use it to settle the matrix's unconfirmed flags and agy's login files. Record the findings in this file.

**Phase 0 results (2026-10-28, `make smoke`).** Builds use the latest packages: claude 2.1.312 + claude-agent-acp 0.99.0,
codex-acp 2.3.0, gemini-cli 0.66.0, grok (xAI installer).

| Agent | Result | Notes |
|-------|--------|-------|
| codex | PASS (19 s) | yolo works: 0 permission requests; shell ran as `agent` in the workspace; home removed |
| grok | PASS (13 s) | yolo works: `[ui] permission_mode = "always-approve"`; `initialize` sends no `agentInfo` |
| claude | PASS (8 s) | starts in `bypassPermissions`: 0 permission requests. First try got a 401 from pasting the browser's code instead of the `sk-ant-oat01-…` token that `claude setup-token` prints |
| gemini | dropped | Google refuses personal OAuth: "This client is no longer supported for Gemini Code Assist for individuals… migrate to Antigravity". Replaced by agy (owner decision) |

- The host's codex, gemini and grok login files had the same hashes after the runs, so the containers don't rotate
  them (yet; recheck after longer sessions).
- Inside the container, `/home/<user>` and `/home/<user>/workarea` contain only the folders leading down to the
  mount, so nothing above the workspace (`AGENTS.md`, `CLAUDE.md`, config) can be found by walking up the tree.

**Phase 1 — claude, codex, grok. (gemini dropped; Google now supports agy instead.)** Base image, `acp-run`, compose, Makefile, smoke tests, VS Code snippet.
Then check in the real extension.

**Phase 2 — opencode, kilo, goose (via llm-proxy), agy.**

**Phases 1–2 results (2026-10-28).** `make smoke` passes for all nine services, each with 0 permission requests, the
shell running as `agent` in the workspace, and the connection's home removed afterwards:

| Service | Time | Model source | Version |
|---------|------|--------------|---------|
| claude | 8 s | subscription token | Claude Code 2.1.312, claude-agent-acp 0.99.0 |
| claude-proxy | 6 s | LiteLLM `/v1/messages`, `nemotron-3-ultra` | same image |
| codex | 23 s | ChatGPT login (`auth.json`) | codex-acp 2.3.0 |
| grok | 11 s | xAI login (`auth.json`) | grok 1.0.70 |
| agy | 11 s | Google AI Ultra login (`acp_token.json`); starts on `gemini-4-argon-high` (`AGY_MODEL`; the server's own default is `gemini-3.8-flash-high`, which gave noticeably terser answers) | agy-acp-server 1.4.4 |
| agy-proxy | 7 s | LiteLLM Gemini route, alias → `nemotron-3-ultra` | same image |
| opencode | 9 s | LiteLLM, `nemotron-3-ultra` | opencode 1.19.5 |
| kilo | 9 s | LiteLLM, `nemotron-3-ultra` | kilo 7.8.18 |
| goose | 5 s | LiteLLM, `nemotron-3-ultra` | goose 1.57.0 |
| muse | 21 s | Meta login (`auth.json`); starts on muse-wonder-1.0, effort max; Model and Effort pickers | Muse Code 1.4.14, muse-acp 0.1.0 (cancel tested: a 120 s command stopped at 12 s) |

The pattern for "subscription vs local model" is **one image, two services** that differ only in environment
(`CLAUDE_AUTH`, `AGY_AUTH`). codex and grok can get a `-proxy` service the same way when needed.

**Phase 3 — hardening.** Reap orphans (see risks), resource limits, optional `codex-proxy` / `grok-proxy`.

## Risks

1. **OAuth refresh-token rotation (codex, grok, agy).** If a container refreshes a copied subscription token,
   the host copy may stop working. Claude avoids this with its long-lived token. Phase 0 checks the others: compare
   the host auth file's hash before and after a run, then log in on the host again. If it does happen, fall back to
   API keys or a login made only for the containers.
2. **Orphaned processes.** Killing the `docker exec` client does not always kill the process inside. `acp-run`
   treats stdin EOF as a disconnect and kills its process group; `make clean` also removes leftovers.
3. **Claude refuses bypassPermissions as root.** Handled by running as non-root user `agent`.
4. **agy image size** (~1 GB unpacked server). Startup on Linux is fast (whole smoke run 7–11 s); it is in the default `AGENTS` list.
5. **Project-level context still applies.** `CLAUDE.md`/`AGENTS.md`/`GEMINI.md` inside `WORKSPACE` are part of the
   project, not memory, so agents will still read them. `~/workarea/tmp` has none today. Nothing **above**
   `WORKSPACE` is visible: only `WORKSPACE` is mounted, so the parent folders inside the container are empty.
6. **llm-proxy must be up first.** opencode and goose depend on the external `openai-proxy_default` network.
   `make up` checks for it and says so if it's missing, instead of failing deep inside compose (done).
7. **Agents can read the proxy key.** In the proxy-backed services `LITELLM_MASTER_KEY` is in the agent's environment
   or config, so any command an agent runs can read it. That's acceptable on this machine; a LiteLLM virtual key
   limited to a budget or to certain models would contain it.
8. **agy writes into the workspace.** Its harness puts its built-in skills in `<session folder>/skills/system/` before
   each turn; nothing configures that path (the server already moved its `brain/` out of the repo for the same reason).
   `acp_teardown` in `docker/agy/setup.sh` removes `skills/` on disconnect, but only if it didn't exist when the
   connection started and holds nothing but `namespace: system` skills. While a session is open the folder is visible,
   and in a project with its own `skills/` the `system/` subfolder is left behind.

## Locked profile (2026-10-28)

Optional hardened profile for environments that allow only an internal model: `compose.locked.yaml`, `locked/`,
`scripts/locked-check*.sh`, `make locked-*`. Design, controls, evidence and residual risks: [SECURITY.md](SECURITY.md).
The per-agent setup scripts read `ACP_LOCKED=1` to deny web tools (OpenCode/Kilo `webfetch`/`websearch`, Claude Code
`WebFetch`/`WebSearch`, Goose: only the `developer` and `todo` extensions) and to switch off OpenCode's background
fetches.
