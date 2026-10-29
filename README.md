# AI coding agents in containers, over ACP

Run AI coding-agent CLIs — Claude Code, Codex, Grok, Antigravity, Muse, OpenCode, Kilo Code, Goose — each in its own
Docker container, and use them from VS Code through an [Agent Client Protocol](https://agentclientprotocol.com) (ACP)
client. Nothing is installed on the workstation except Docker and the editor extension.

Every connection starts as if the agent were freshly installed: a new container, an empty home folder, no history, no
memories, no user config, and only the folder you have open in VS Code. Disconnect and it is all gone.

An optional **locked profile** goes further for corporate use: the agents have no internet access at all, reach a
model only through one approved gateway that holds the credential, and run with a hardened container configuration.
It comes with an automated check that proves each control. See [Locked profile](#locked-profile) and
[docs/SECURITY.md](docs/SECURITY.md).

## Why not just install the agent?

Installed on a workstation (as a CLI, or as an editor extension such as Kilo Code), an agent runs with all of the
user's rights: it can read SSH keys and cloud credentials, run commands, reach any website, keep conversation history
in the home folder, and update itself. Its own settings are the only thing restricting it.

Here the restrictions come from the container instead:

| | Installed on the workstation | In this project |
|---|---|---|
| Files it can see | Everything the user can read | Only the folder open in VS Code |
| Credentials | The user's own, all of them | Only what that agent needs (locked profile: none) |
| History, memories, config | Persist in the home folder | Thrown away at disconnect |
| Network | Anything | Normal profile: anything. Locked profile: one model gateway and an allowlist |
| Privileges | The user's | Non-root, no capabilities, read-only system (locked profile) |
| Who enforces it | The agent's own settings | Docker and the kernel |

## How it works

```
VS Code ── ACP Client extension
             │ starts:  bin/acp-connect <agent>      (ACP = JSON-RPC over stdin/stdout; no ports)
             ▼
   docker compose run --rm <agent>   ── a new container for this connection
             │  mounts only the open folder, at the same path
             ▼
   acp-run   ── creates an empty home in /tmp, writes the agent's config (auto-approve, no memory, no telemetry),
             │  starts the agent's ACP command, and deletes the home when the editor disconnects
             ▼
   the agent's ACP entry point (native, or an adapter)
```

| Agent | ACP entry point | Model | Notes |
|-------|-----------------|-------|-------|
| `claude` | `claude-agent-acp` (ACP adapter) | Anthropic, subscription token | |
| `claude-proxy` | same image | local LiteLLM proxy (Anthropic-format route) | |
| `codex` | `codex-acp` | OpenAI, ChatGPT login | |
| `grok` | `grok agent stdio` | xAI login | |
| `agy` | Google's `agy_acp_server` | Google login; starts on Gemini 4 Argon | |
| `agy-proxy` | same image | local LiteLLM proxy (Gemini-format route) | |
| `muse` | `docker/muse/muse-acp.mjs` (our adapter on Meta's SDK) | Meta login | Muse has no ACP mode of its own |
| `opencode` | `opencode acp` | local LiteLLM proxy | |
| `kilo` | `kilo acp` | local LiteLLM proxy | the CLI behind the Kilo Code extension |
| `goose` | `goose acp` | local LiteLLM proxy | |
| `*-locked` | as above | through `llm-gateway` only | [Locked profile](#locked-profile) |

## Requirements

- Docker with Compose v2 (tested on Docker Desktop 4.x with WSL 2, Docker 29, Compose 5).
- VS Code (or VS Code Insiders) with the **ACP Client** extension by Jun Han (`formulahendry.acp-client`). In a
  Remote-WSL window it must be installed on the WSL side, where `docker` runs.
- Node.js on the host, only for `make smoke`.
- For the agents that use a local model: an OpenAI-compatible gateway such as [LiteLLM](https://docs.litellm.ai)
  running in Docker (the defaults expect the `llm-proxy` service on the `openai-proxy_default` network).
- For the vendor agents: that vendor's login on the host (`codex login`, `grok login`, …); see `.env.example`.

## Quick start (normal profile)

```bash
cp .env.example .env          # fill in what you use: CLAUDE_CODE_OAUTH_TOKEN, LITELLM_MASTER_KEY, models
make build                    # base image + one image per agent (latest CLI versions)
make smoke                    # optional: an ACP session with every agent
make client-config            # prints the "acp.agents" block for VS Code
```

Paste the printed block into your VS Code settings (in a WSL window: **Preferences: Open Remote Settings (JSON)**).
Then open a project folder, pick e.g. **claude (container)** in the ACP Client panel, and chat. The agent works in
that folder and nowhere else. If no folder is open, it uses `~/workarea/tmp` (`ACP_DEFAULT_DIR`).

VS Code merges `acp.agents` with the extension's built-in `npx` agents, so those still appear. They run on the host;
use the **(container)** entries.

## Locked profile

For environments where code may only go to an approved, internally hosted model. It is **optional**: nothing in it is
used unless you run the `locked-*` targets or connect to a `*-locked` agent.

What it adds (details, threat model and residual risks in [docs/SECURITY.md](docs/SECURITY.md)):

- **No route out.** The agents sit on a Docker *internal* network: no internet, no LAN, no host, no outside DNS.
- **One model gateway.** `llm-gateway` (nginx) is the only path to a model. It forwards model API paths to
  `LOCKED_LLM_UPSTREAM`, adds the credential itself, and logs every call. The agents hold only a placeholder key.
- **Allowlisted egress.** `egress` (Squid) allows only the domains in `locked/egress-allowlist.txt` — none as shipped
  — and logs every attempt.
- **Hardened containers.** Non-root, all Linux capabilities dropped, `no-new-privileges`, read-only root filesystem,
  CPU, memory and process limits, optional read-only workspace.
- **No web tools.** Each agent's web fetch/search tools are switched off in its configuration.

Locked agents: `opencode-locked`, `kilo-locked`, `goose-locked`, `claude-locked`.

### Run it

```bash
# In .env (defaults shown): where the gateway sends model calls and with which key
#   LOCKED_LLM_UPSTREAM=http://llm-proxy:8000
#   LOCKED_LLM_KEY=...                      (defaults to LITELLM_MASTER_KEY)
#   LOCKED_UPSTREAM_NETWORK=openai-proxy_default
make locked-build             # agent images + nginx + squid
make locked-up                # start llm-gateway and egress
make locked-check             # verify every control (no model calls); exit code 0 = all passed
make locked-smoke             # ACP sessions through the gateway
make locked-client-config     # VS Code entries for the locked agents
make locked-logs              # audit: model calls and outbound attempts
make locked-down              # stop the gateway and proxy
```

### Verify it (for testers)

1. `make locked-check` — 17 checks per agent, from inside its container: no internet by name or IP, no outside DNS,
   the host unreachable, the proxy refusing unlisted domains, the gateway working without a key and refusing other
   paths, non-root, no capabilities, no privilege escalation, read-only root, no Docker socket, only the workspace
   mounted, a process limit, web tools denied, and the real key absent. Expected last line: `ALL CHECKS PASSED`.
2. Connect a `*-locked` agent in VS Code and try to break out — the scripted list is in
   [docs/SECURITY.md → Manual](docs/SECURITY.md#manual-in-the-editor).
3. Watch `make locked-logs` while you do: the gateway shows each model call; the proxy shows each refused attempt
   (`TCP_DENIED/403`).

In our own runs the agents tried, unprompted, to reach telemetry (PostHog), vendor services (Kilo), model catalogues
(models.dev, models.opencode.ai) and the npm registry. All were refused, and every agent kept working.

## Make targets

| Target | Does |
|--------|------|
| `build` / `rebuild` | Build the images (`rebuild`: no cache, newest CLIs) |
| `smoke [A=agent]` | ACP session test: initialize, a prompt, a shell command; checks auto-approve and clean-up |
| `client-config` | VS Code `acp.agents` block for the normal profile |
| `up` / `down` / `restart` / `ps` / `logs` / `shell A=agent` / `versions` | Long-running containers (optional; `docker exec` access with a fixed workspace) |
| `prune` | Remove per-connection containers left by a killed editor (also ends live sessions) |
| `clean` | Remove containers, images and the locked profile's networks |
| `locked-build`, `locked-up`, `locked-check`, `locked-smoke`, `locked-logs`, `locked-client-config`, `locked-down` | Locked profile, above |

## Repository layout

```
bin/acp-connect               what the editor starts: one container per connection, mounting the open folder
compose.yaml                  one service per agent (normal profile)
compose.locked.yaml           the locked profile: internal network, gateway, egress proxy, hardened agents
locked/                       gateway rules, egress policy and allowlist
docker/base/                  base image: acp-run (per-connection home), acp-shim (cwd mapping, start-up mode)
docker/<agent>/               Dockerfile + setup.sh (that agent's config, credentials, locked settings)
docker/muse/muse-acp.mjs      ACP adapter for Muse, on Meta's @muse-code/sdk
scripts/acp-smoke.mjs         ACP smoke test
scripts/locked-check*.sh      locked profile verification
docs/SECURITY.md              security design for reviewers
docs/SPEC.md                  design notes and per-agent findings
```

## Limitations

- The images install the **latest** CLI versions at build time. Pin versions and build from internal mirrors before
  relying on this in production (see docs/SECURITY.md).
- Changes an agent makes to the open folder are real; review them like any untrusted contribution.
- Past sessions cannot be resumed — by design.
- Vendor agents copy their login file into each connection; if a vendor rotates refresh tokens, a long session may
  refresh a copy the host never sees (Claude avoids this with a long-lived token).
