# Oracle Linux 8 server or VM (not WSL): from a fresh install to all agents working

This is the complete procedure for a normal Oracle Linux 8.10 install (bare metal or a VM), running this project and
[openai-proxy](https://github.com/k82l0804/openai-proxy) on **rootless Podman**. For WSL 2, use
[podman-install.md](podman-install.md) instead; that file also explains *why* each Podman setting is needed.

**Verified** on 2026-11-24 on Oracle Linux 8.10 in a Hyper-V VM (kernel 5.15 UEK7, SELinux enforcing), Podman 4.9.4,
netavark 1.10, Docker Compose v5.8.0, Node.js 22, both repositories on the `podman-support` branch:

| Test | Result |
|---|---|
| `make smoke` (every agent through `bin/acp-connect`, as VS Code starts them) | 12 / 12 pass |
| `make locked-check` | 120 / 120 checks pass |
| `make locked-smoke` | 7 / 7 pass |
| Files an agent writes in the workspace | owned by you, SELinux label `container_file_t` |

What a real OL8 host needs that WSL doesn't (or the reverse):

| | Real OL8 | WSL 2 |
|---|---|---|
| cgroups | **Boots on v1.** Switch to v2 (kernel argument + reboot), or rootless Podman can't apply the locked profile's limits | already v2 |
| SELinux | **Enforcing.** Every bind mount needs `:z` (both repos' `podman-support` branches have it) | not present |
| `newuidmap` capabilities | normally intact | lost; must be re-set |
| `/etc/wsl.conf`, WSL restart | not used | required |
| Logging in | directly as the user (SSH or console). `sudo su - user` gives no `XDG_RUNTIME_DIR` and no `systemctl --user` | WSL shell |

## 1. Prerequisites

- Oracle Linux 8.10 with the `ol8_baseos_latest` and `ol8_appstream` repositories, and a user with sudo.
- Outbound HTTPS to: `yum.oracle.com`, `github.com` (Compose, repositories), `docker.io` / `ghcr.io` (images),
  `registry.npmjs.org`, and each vendor's install and API hosts. If the server reaches the internet through an HTTP
  proxy, set `http_proxy`/`https_proxy`/`no_proxy` for dnf, curl and Podman before you start (not verified here; Podman
  passes these variables into builds by default).
- An OpenRouter key (or other provider key) for openai-proxy; a Claude subscription for `claude`; the vendor
  subscriptions for the other vendor agents you want.

## 2. Root setup, then reboot

```bash
mkdir -p ~/workarea && cd ~/workarea
git clone -b podman-support https://github.com/k82l0804/openai-proxy.git
git clone -b podman-support https://github.com/k82l0804/ai-vendor-agent-cli-containers.git
sudo bash ai-vendor-agent-cli-containers/scripts/ol8-host-setup.sh
sudo reboot
```

[`scripts/ol8-host-setup.sh`](../scripts/ol8-host-setup.sh) does the following (safe to run again):

1. Enables the `container-tools:ol8` and `nodejs:22` module streams and installs Podman, `podman-docker` (a `docker`
   command that runs `podman`), netavark, aardvark-dns, Node.js 22, git, make, jq, ripgrep and ShellCheck.
2. Checks the file capabilities on `newuidmap`/`newgidmap` and your `/etc/subuid` and `/etc/subgid` ranges, and fixes
   them if missing.
3. Installs Docker Compose v5.8.0 (SHA-256 checked) as `/usr/local/bin/docker-compose`. `podman compose` runs it
   against Podman's socket. Use this, not `podman-compose`.
4. Delegates the `cpu cpuset io memory pids` cgroup controllers to user sessions (EL8's systemd delegates only `memory
   pids`), and enables lingering so your user services and containers keep running without a login.
5. Adds `systemd.unified_cgroup_hierarchy=1` to the kernel command line (cgroups v2 after the reboot).

## 3. After the reboot: check the host, switch Podman to netavark

Log in as your user directly (SSH or console), then:

```bash
stat -fc %T /sys/fs/cgroup                         # cgroup2fs
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
                                                   # cpuset cpu io memory pids
getenforce                                         # Enforcing is fine
echo $DBUS_SESSION_BUS_ADDRESS                     # unix:path=/run/user/<uid>/bus, or empty
```

**Check the D-Bus address over SSH, not only in a desktop terminal.** Rootless Podman asks your user's systemd, over
D-Bus, for a scope per container. Some sites set `DBUS_SESSION_BUS_ADDRESS` in a login script (seen at work:
`/etc/profile.d/ssh-x-forward.sh`/`.csh`, for SSH X forwarding) to a `unix:abstract=/tmp/dbus-…` bus that has no
systemd behind it. `podman run` then fails over SSH, and so over VS Code Remote-SSH, with `unable to start unit …
Interactive authentication required`, while the same command works in a desktop terminal. If the address is
anything other than your user bus, add this to the **end** of `~/.bashrc` (after `/etc/profile.d` has run), then log in
again:

```bash
systemctl --user enable --now dbus.socket          # the user bus, also without a desktop login
cat >> ~/.bashrc <<'EOF'
# Podman needs the systemd user bus; a site login script may point SSH logins at an X-forwarding bus instead.
if [ -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi
EOF
```

`~/.bash_profile` must source `~/.bashrc` (it does by default on OL8). Don't answer the polkit prompt with sudo or a
smartcard PIN instead: that would create the container's scope in the *system* systemd, which isn't rootless any more.

Podman 4.x on EL8 uses CNI when CNI plugins are installed. Switch to netavark **before any containers exist**.
`system reset` deletes all of *your* rootless containers, images, volumes and networks (other users' aren't
touched); on a server where you already use Podman, check `podman ps -a`, `podman images` and `podman volume ls`
first, and if anything there matters, run `podman system migrate` after writing `containers.conf` instead of the
reset.

```bash
mkdir -p ~/.config/containers
printf '[network]\nnetwork_backend = "netavark"\n' > ~/.config/containers/containers.conf
podman system reset -f
systemctl --user enable --now podman.socket
podman info --format '{{.Host.CgroupManager}} {{.Host.CgroupsVersion}} {{.Host.NetworkBackend}}'
                                                   # systemd v2 netavark
docker compose version                             # Docker Compose version v5.8.0 (after a ">>>> Executing
                                                   # external compose provider" banner, which is harmless)
```

Optional, for tools other than this project's Makefiles: `echo 'export
DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"' >> ~/.bashrc`.

## 4. Podman smoke test

```bash
podman run --rm docker.io/library/hello-world
podman network create --internal t-int && \
  { podman run --rm --network t-int docker.io/library/alpine wget -T3 -qO- http://example.com && echo LEAK || echo blocked OK; \
    podman network rm t-int; }
podman run --rm docker.io/library/alpine wget -T5 -qO- http://example.com >/dev/null && echo egress ok
podman run --rm --cpus 0.5 --memory 64m --pids-limit 50 docker.io/library/alpine \
  cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max /sys/fs/cgroup/pids.max
# expected: blocked OK, egress ok, then 50000 100000 / 67108864 / 50
```

## 5. openai-proxy

```bash
cd ~/workarea/openai-proxy
cp .env.example .env && chmod 600 .env
sed -i "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=sk-$(openssl rand -hex 24)|" .env
vi .env                                            # OPEN_ROUTER_API_KEY (and GEMINI_API_KEY / GROK_API_KEY if used)
make up && make health                             # "I'm alive!"
./scripts/list-models.sh
MODEL=nemotron-3-ultra ./scripts/test-chat.sh      # one real call (the agents' default model)
podman ps                                          # llm-proxy becomes (healthy) after ~20 s
```

Keep the folder name `openai-proxy`: it makes the network `openai-proxy_default` that the agents join.

## 6. Agent images

```bash
cd ~/workarea/ai-vendor-agent-cli-containers
cp .env.example .env && chmod 600 .env
# LITELLM_MASTER_KEY: the same value as in openai-proxy/.env
sed -i "s|^LITELLM_MASTER_KEY=.*|$(grep '^LITELLM_MASTER_KEY=' ../openai-proxy/.env)|" .env
# CLAUDE_CODE_OAUTH_TOKEN: run `claude setup-token` (on any machine with Claude Code) and paste the token into .env
mkdir -p ~/workarea/tmp                            # default workspace when no folder is open
make build                                         # about 7 GB of images; the first run takes a while
```

## 7. Test the agents that need no vendor login

These use openai-proxy (`nemotron-3-ultra` unless `.env` says otherwise):

```bash
ACP_SMOKE_VIA=connect ACP_SMOKE_CWD=$HOME/workarea/tmp \
  node scripts/acp-smoke.mjs claude-proxy codex-proxy grok-proxy agy-proxy opencode kilo goose
```

Each must print `=== <agent>: PASS`. `claude` needs only `CLAUDE_CODE_OAUTH_TOKEN` in `.env`; add it to the list.

## 8. Vendor logins, then the vendor agents

Each vendor agent copies a login file from your home folder (mounted read-only) into each new container. Log in once
on the host:

| Agent | Install the CLI on the host | Log in | File the container reads |
|---|---|---|---|
| claude | – | `claude setup-token` → `.env` | `CLAUDE_CODE_OAUTH_TOKEN` |
| codex | `npm i -g @openai/codex` | `codex login` | `~/.codex/auth.json` |
| grok | `curl -fsSL https://x.ai/cli/install.sh \| bash` (or `npm i -g @xai-official/grok`) | `grok login` | `~/.grok/auth.json` |
| muse | `curl -fsSL https://dev.meta.ai/install.sh \| bash` | `muse login` | `~/.config/muse/auth.json` |
| agy | – | In VS Code's ACP Client, connect once to the extension's **built-in** Antigravity agent (it runs on the host, not in a container) and sign in with Google | `~/.gemini/antigravity-acp/acp_token.json` |

For grok, use xAI's own CLI. `npm i -g @vibe-kit/grok-cli` is a different, third-party CLI and writes no `auth.json`.

Restrict the login files to your user: `chmod 600 ~/.gemini/antigravity-acp/acp_token.json` (it was created
group-readable here).

```bash
ls -l ~/.codex/auth.json ~/.grok/auth.json ~/.config/muse/auth.json ~/.gemini/antigravity-acp/acp_token.json
ACP_SMOKE_VIA=connect ACP_SMOKE_CWD=$HOME/workarea/tmp node scripts/acp-smoke.mjs claude codex grok muse agy
```

## 9. Locked profile (optional)

```bash
make locked-build
make locked-check                                  # last line: ALL CHECKS PASSED
ACP_SMOKE_CWD=$HOME/workarea/tmp make locked-smoke
```

## 10. VS Code

Connect with **Remote-SSH** to the server and install the **ACP Client** extension (`formulahendry.acp-client`) on
the remote side. Run `make client-config` (and `make locked-client-config`) and paste the printed `acp.agents` block
into **Preferences: Open Remote Settings (JSON)**. Open a project folder and pick an agent marked **(container)**.

Opening a folder mounts it with `:z`, which gives it the SELinux label `container_file_t`. Host tools keep working
with it. `bin/acp-connect` never mounts `/`, `/home`, `/root` or your home folder itself.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| openai-proxy never gets healthy; `podman logs openai-proxy-llm-proxy-1` shows `Exception: Config file not found: /app/config.yaml` | SELinux denies the container access to the mounted config. Its mounts need `:z` (`openai-proxy` `podman-support` branch, `docker-compose.yml`). Any other bind mount you add needs `:z` too. |
| `make build` fails with `copying system image ... parsing image configuration ... EOF` | Docker Hub's CDN dropped the download. Pull the base image until it succeeds, then rerun: `until podman pull docker.io/library/node:22-bookworm-slim; do sleep 5; done; make build` |
| `systemctl --user` fails with `Failed to connect to bus` | You switched user with `su`/`sudo -u`. Log in as the user directly. |
| `podman run` fails over SSH with `runc create failed: … unable to apply cgroup configuration: unable to start unit … Interactive authentication required`, but works in a desktop terminal | `DBUS_SESSION_BUS_ADDRESS` points at a bus without systemd (a site login script for X forwarding, `unix:abstract=/tmp/dbus-…`), so runc falls back to the system bus and polkit refuses. Point it at your user bus in `~/.bashrc`: section 3. |
| `cat …/user@<uid>.service/cgroup.controllers`: no such file | Check for typos first, then use the path systemd reports: `cat /sys/fs/cgroup$(systemctl show user@$(id -u).service -p ControlGroup --value)/cgroup.controllers`. If `systemctl is-active user@$(id -u).service` isn't `active`, you have no systemd user session (see the row above). |
| `podman info` shows `cgroupfs v1` | The reboot after the setup script hasn't happened, or the grub change didn't apply: `sudo grubby --info=DEFAULT \| grep unified`. |
| `podman info` shows `cni` | Step 3's `containers.conf` is missing. |
| `runc create failed: user namespaces enabled, but no mapping found for uid 0` on the first `make up` | Two services sharing an image race on Podman's first keep-id copy. Run `make up` again. |
| A vendor agent stops with `acp-run: /creds/... missing` | That vendor's login file isn't on the host (section 8). |
| Other machines can't reach openai-proxy | `sudo firewall-cmd --add-port=8000/tcp --permanent && sudo firewall-cmd --reload`. Not needed for local agents. |
