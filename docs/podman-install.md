# Running this project on Podman (Oracle Linux 8 on WSL 2)

This is how to set up a fresh Oracle Linux 8.10 WSL 2 distribution so that this project runs on **rootless Podman**
instead of Docker. The `docker compose` commands in the Makefile and `bin/acp-connect` stay as they are: the real
Docker Compose v2 binary talks to Podman's Docker-compatible API socket. No Docker Engine is installed.

Steps 1–6 are done once, as your normal user (with sudo). Step 7 is a restart of the distribution, and steps 8–10 come
after it. Each step says what problem it solves, because most of them are fixes for things that fail silently or with
misleading errors on WSL.

Tested with: Oracle Linux 8.10 (WSL 2, kernel 6.18), Podman 4.9.4 (`container-tools:ol8` module), netavark,
Docker Compose v5.8.0, Node.js 22.

## 1. sudo without a password (optional)

Only needed if an automated assistant does the setup; skip it if you type the commands yourself.

```bash
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$USER
sudo chmod 0440 /etc/sudoers.d/$USER
sudo visudo -c                     # must print "parsed OK" for every file
```

The keyword is `NOPASSWD`, not `NOPASSWORD`. A typo leaves a file sudo can't parse, and sudo keeps asking for a password.

## 2. Packages

```bash
sudo dnf -y install oracle-epel-release-el8 dnf-plugins-core      # EPEL: ripgrep, ShellCheck
sudo dnf -y module reset nodejs
sudo dnf -y module enable nodejs:22                                # the default stream is Node 10
sudo dnf -y module enable container-tools:ol8                      # rolling stream: newest Podman for OL8
sudo dnf -y install git make gcc gcc-c++ jq ripgrep ShellCheck vim-enhanced tar unzip bzip2 which procps-ng \
  bash-completion curl wget openssl nodejs npm python3.12 python3.12-pip \
  podman podman-docker buildah skopeo netavark aardvark-dns slirp4netns fuse-overlayfs containers-common
sudo touch /etc/containers/nodocker    # silences podman-docker's "Emulate Docker CLI using podman" notice
```

`podman-docker` provides a `docker` command that runs `podman`, so `docker build`, `docker exec`, `docker network
inspect` and so on in the Makefile work unchanged.

## 3. Fix `newuidmap` / `newgidmap` capabilities

**Symptom:** every rootless Podman command fails with

```
newuidmap: write to uid_map failed: Operation not permitted
Error: cannot set up namespace using "/usr/bin/newuidmap": should have setuid or have filecaps setuid
```

**Cause:** the WSL root filesystem lost the file capabilities that the `shadow-utils` RPM sets on these two binaries.
`rpm -V shadow-utils` shows them with a `P` (capabilities differ) flag.

**Fix:**

```bash
sudo rpm --setcaps shadow-utils
getcap /usr/bin/newuidmap /usr/bin/newgidmap    # expect cap_setuid=ep and cap_setgid=ep
podman system migrate
```

Also check that your user has a sub-ID range (it did here, `100000:65536`):

```bash
grep "^$USER:" /etc/subuid /etc/subgid
# if missing: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
```

## 4. Use the netavark network backend

**Symptom:** `podman info --format '{{.Host.NetworkBackend}}'` prints `cni`. Podman 4.x on EL8 picks CNI when it finds
CNI plugins installed. CNI is deprecated, and this project's locked profile needs what netavark does well: `internal:
true` networks with no route out, and name resolution between containers through aardvark-dns.

**Fix** (before any containers or networks exist, because `system reset` deletes them all):

```bash
mkdir -p ~/.config/containers
cat > ~/.config/containers/containers.conf <<'EOF'
[network]
network_backend = "netavark"
EOF
podman system reset -f
podman info --format '{{.Host.NetworkBackend}}'    # netavark
```

## 5. Docker Compose v2, without Docker

```bash
V=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
sudo curl -fsSL -o /usr/local/bin/docker-compose \
  "https://github.com/docker/compose/releases/download/$V/docker-compose-linux-x86_64"
sudo chmod 0755 /usr/local/bin/docker-compose
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo ln -sf /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
```

Use the real Compose v2 binary, not `podman-compose`. This project relies on `compose run --rm -T --no-deps`, YAML merge
keys, `--project-directory` and internal networks, and `podman-compose` handles these differently or not at all.

> `podman-docker`'s `docker` is a shell script that runs `podman`, so `docker compose …` becomes `podman compose …`.
> Podman 4.9 then runs the first compose provider it finds, `docker-compose` in `/usr/local/bin`, pointed at the Podman
> socket. Both `docker compose` and `docker-compose` therefore end up in the same binary.

## 6. WSL settings: systemd, no Windows PATH

```bash
sudo tee /etc/wsl.conf >/dev/null <<EOF
[boot]
systemd=true
command=mount --make-rshared /

[user]
default=$USER

[interop]
appendWindowsPath=false
EOF
```

- **`systemd=true`**: rootless Podman's API socket (`podman.socket`) is a systemd user unit. Without systemd there is
  no socket for Compose, and no healthcheck timers (openai-proxy's healthcheck uses them).
- **`command=mount --make-rshared /`**: on WSL, `/` stays a `private` mount even with systemd as PID 1, and every
  Podman command warns `"/" is not a shared mount`. This runs as root each time the distribution starts. Check with
  `findmnt -o TARGET,PROPAGATION /`, which should print `shared`.
- **`appendWindowsPath=false`**: otherwise Docker Desktop's `docker` from `C:\Program Files\Docker\…` (and Windows
  `node`, `git` and others) are on the WSL PATH, and which engine runs depends on PATH order. VS Code's `code` command
  still works, through its own remote CLI.

Point Docker clients at the Podman socket, in `~/.bashrc`:

```bash
export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
```

## 7. Restart the distribution

From PowerShell on Windows:

```powershell
wsl -l -v                          # the distribution's name
wsl --terminate <DistroName>       # or: wsl --shutdown  (stops every distribution)
```

Then open a new WSL shell, or reopen the folder in VS Code. Check: `ps -p 1 -o comm=` prints `systemd`.

**Other WSL distributions share the cgroup tree.** Every WSL 2 distribution runs in the same VM and sees the same
`/sys/fs/cgroup`. If another distribution with `systemd=true` is running and has a user with the same UID (usually
1000), its user manager already sits at `/user.slice/user-1000.slice/user@1000.service`. This distribution's user
manager then fails to start, and `systemctl --user` prints `Failed to connect to bus`. The journal shows:

```text
user@1000.service: Failed to attach to cgroup /user.slice/user-1000.slice/user@1000.service: Device or resource busy
user@1000.service: Failed at step CGROUP spawning /usr/lib/systemd/systemd: Device or resource busy
```

`cat /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/init.scope/cgroup.procs` lists PIDs as `0`, because
the processes belong to the other distribution's PID namespace. The fix is to stop the other distributions, then start
the user manager again:

```powershell
wsl -l -v                          # which distributions are Running
wsl --terminate <OtherDistro>      # every other Linux distribution with systemd
```

```bash
sudo systemctl reset-failed user@$(id -u).service
sudo systemctl start user@$(id -u).service
systemctl --user is-system-running    # running (or degraded)
```

Whichever distribution starts its user manager first wins. A distribution started later prints
`wsl: Failed to start the systemd user session for '<user>'`. Its shell still works, but it has no `systemctl --user`.
Docker Desktop's WSL integration doesn't need the user session, so Docker in that other distribution keeps working. To
avoid the clash for good, either set `systemd=false` in the other distributions' `/etc/wsl.conf`, or give the user a
different UID in one of them.

## 8. Start the Podman API socket and enable lingering

systemd 239 (EL8) delegates only the `memory` and `pids` cgroup controllers to user sessions. The locked profile's
`cpus:` limit also needs `cpu` (and `cpuset`/`io` for completeness):

```bash
sudo mkdir -p /etc/systemd/system/user@.service.d
sudo tee /etc/systemd/system/user@.service.d/delegate.conf >/dev/null <<'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
# expected: cpuset cpu io memory pids
```

If the `cat` prints nothing even though `systemctl show user@$(id -u).service -p DelegateControllers` lists the
controllers, systemd hasn't re-applied them to the cgroup tree yet. This happened after the user manager had failed to
start (see step 7). Run `sudo systemctl daemon-reload` again and check once more.

```bash
systemctl --user enable --now podman.socket
sudo loginctl enable-linger $USER        # keep user services (and long-running containers) up without a login
ls -l "$XDG_RUNTIME_DIR/podman/podman.sock"
docker-compose version                   # Docker Compose version v5.8.0
docker compose version                   # same, via podman-docker → podman compose → docker-compose
podman --remote version                  # Server: Podman Engine (plain `docker version` shows only the client)
podman info --format '{{.Host.CgroupManager}} {{.Host.CgroupsVersion}} {{.Host.NetworkBackend}}'
# expected: systemd v2 netavark
```

`docker compose` prints a banner, `>>>> Executing external compose provider "/usr/local/bin/docker-compose"`, on
stderr. It's harmless.

## 9. Smoke test

```bash
podman run --rm docker.io/library/hello-world
podman network create --internal t-int && \
  podman run --rm --network t-int docker.io/library/alpine wget -T3 -qO- http://example.com; \
  podman network rm t-int     # the wget must fail: internal network, no route out
podman run --rm docker.io/library/alpine wget -T5 -qO- http://example.com >/dev/null && echo egress ok
podman run --rm --cpus 0.5 --memory 64m --pids-limit 50 docker.io/library/alpine \
  cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max /sys/fs/cgroup/pids.max
# expected: 50000 100000 / 67108864 / 50  (the locked profile's limits are enforced)
```

## On a real OS (bare metal or VM) instead of WSL

The steps above were run on WSL 2. On a normal Oracle Linux 8 / RHEL 8 install, most of them are the same. These are
the differences, step by step. They come from how the two environments differ and **have not been tested on a non-WSL
machine yet**.

| Step | WSL 2 | Real OL8 / RHEL 8 |
|---|---|---|
| 2. Packages | as written | Same. If Docker Engine (`docker-ce`, `moby-engine`) is installed, remove it: `podman-docker` conflicts with it, and two engines on one host make it unclear which one ran a container. |
| 3. `newuidmap` capabilities | Lost by the WSL root filesystem; fix with `rpm --setcaps` | Normally intact. Just check `getcap /usr/bin/newuidmap` and run the fix only if it prints nothing. |
| 4. netavark | Needed | Still needed on EL8: Podman 4.x picks CNI when CNI plugins are installed. (EL9 and Fedora default to netavark.) |
| cgroups v2 | Already v2 (the WSL kernel) | **EL8 boots on cgroups v1.** Rootless Podman then can't apply the locked profile's `mem_limit`, `cpus` and `pids_limit`. Switch to v2: `sudo grubby --update-kernel=ALL --args=systemd.unified_cgroup_hierarchy=1`, then reboot. Check with `stat -fc %T /sys/fs/cgroup`, which should print `cgroup2fs`. |
| cgroup delegation | See step 8 | The same drop-in as in step 8 (below), so that rootless containers can be given CPU and I/O limits. |
| SELinux | Not present on WSL | **Enforcing by default.** Containers can't read bind-mounted folders under `$HOME` until those folders are relabelled. The compose files need `:z` on workspace and credential mounts, or `security_opt: [label=disable]`. The podman-support branch handles this; see *Differences under Podman* below. |
| 6. `/etc/wsl.conf` | Required | **Skip.** systemd is already PID 1, `/` is already a shared mount, and there is no Windows PATH. |
| 7. Restart | `wsl --terminate` | Not needed (except a reboot after the cgroups v2 change). |
| 8. User services | as written | Log in as the user directly (console, SSH, or `machinectl shell $USER@`). `sudo su - user` gives no `XDG_RUNTIME_DIR` and no user systemd instance, so `systemctl --user` and the socket fail. |
| Firewall | none | firewalld is fine with netavark for container-to-container traffic. Open port 8000 only if other machines should reach openai-proxy: `sudo firewall-cmd --add-port=8000/tcp --permanent && sudo firewall-cmd --reload`. |
| VS Code | Remote-WSL window | Remote-SSH window (or local). The ACP Client extension must run on the machine where `podman` runs. |

## 10. Build and run the project

See the README's Quick start: `make build`, `make smoke`, and so on. The rest of this section is about differences
under Podman.

### Differences under Podman

Nothing changes in how you use the project: the same `make` targets and the same VS Code configuration. What the
branch does differently, and why:

| What | How it's handled |
|---|---|
| **Which engine** | `bin/acp-compose` picks it. It uses Docker if `docker` is the real Docker; otherwise it uses Podman, including when `docker` is podman-docker's emulation. The Makefile, `bin/acp-connect` and the scripts all go through it. Force one with `ACP_ENGINE=docker` or `ACP_ENGINE=podman`. Under Podman it runs `podman compose`, which points Docker Compose at the Podman socket itself, so `DOCKER_HOST` doesn't need to be set where VS Code starts `acp-connect`. |
| **Workspace file ownership** | In a rootless container, your UID is root and the image's user (UID 1000) maps to a subordinate UID such as 100999. That user then can't write to your workspace at all. `bin/acp-compose` sets `ACP_USERNS=keep-id`, which the compose files use as `userns_mode`, so UID 1000 inside is you outside. Under Docker the variable is empty and nothing changes. Running `docker compose` / `podman compose` directly, without the wrapper, skips this. |
| **SELinux** | Bind mounts carry `:z` (shared label), so containers can read and write them when SELinux is enforcing. Where SELinux is off (WSL, Ubuntu) it does nothing, under either engine. |
| **Image names** | Fully qualified (`docker.io/library/node`, `docker.io/library/nginx`, `docker.io/ubuntu/squid`), because Podman doesn't assume Docker Hub for short names. The images built here show up as `docker.io/library/acp-*`, except `localhost/acp-base`. |
| **Locked profile: DNS** | Podman's network DNS (aardvark-dns 1.10 on EL8) forwards outside names even from an `internal` network, so DNS would be a way out. The locked agents get `dns: [127.0.0.1]`, an upstream resolver that doesn't exist: outside names fail, while `llm-gateway` and `egress` still resolve. Docker doesn't forward from internal networks, so there this changes nothing. |
| **Locked profile: extra mounts** | Podman adds empty tmpfs mounts at `/run`, `/var/tmp` and `/run/.containerenv` to read-only containers, and its init binary at `/run/podman-init`. `scripts/locked-check-inside.sh` accepts exactly these, and only as tmpfs (the init binary by path, like `docker-init`). |
| **Compose recreates containers on every `up`** | Podman 4.x reports no `NetworkID` for a container's networks. Docker Compose (5.8 here) reads that as a change, so every `up` or `run` with dependencies recreates the running containers. For a locked connection, `bin/acp-connect` therefore starts `llm-gateway` and `egress` with `up --no-recreate` and then runs the agent with `--no-deps`, so a new connection doesn't restart the gateway under the others. `scripts/locked-check.sh` uses `--no-deps` for the same reason. An explicit `make up`, `make locked-up` or `make restart` still recreates; that's harmless. |
| **First `make up`** | It can fail once with `runc create failed: user namespaces enabled, but no mapping found for uid 0`. On first use, Podman makes a UID-mapped copy of each image for `keep-id`, and two services sharing an image (`claude` and `claude-proxy`) can race on it. Run `make up` again; it hasn't recurred once the copies exist. |
| **Healthchecks** | Podman's Docker-compatible API splits healthcheck `CMD` arguments on spaces (this matters for openai-proxy's healthcheck, not this project's). Healthchecks also need the systemd user session (step 8), because Podman runs them from systemd timers. |

Verified on Oracle Linux 8.10 under WSL 2 (rootless Podman 4.9.4, Docker Compose 5.8.0):
- `make build`
- `make locked-check`: all checks pass
- `make locked-smoke`: all 7 locked agents
- `make smoke` for `claude` and the 7 proxy agents

Not yet verified: the subscription agents `codex`, `grok`, `muse` and `agy` (they need their host logins), and a real
(non-WSL) EL8 host with SELinux enforcing and cgroups v1 (see the table above).
