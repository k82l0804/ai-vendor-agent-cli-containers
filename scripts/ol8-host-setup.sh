#!/usr/bin/env bash
# Root part of the Oracle Linux 8 server setup (docs/podman-install-ol8.md). Safe to run again.
#   sudo bash scripts/ol8-host-setup.sh        then: sudo reboot
# Installs rootless Podman with netavark, podman-docker, Docker Compose v2 and Node.js 22; delegates cgroup
# controllers to user sessions; enables lingering; switches the kernel to cgroups v2 (takes effect after the reboot).
# COMPOSE_VERSION=vX.Y.Z overrides the Compose release (default: the one this was verified with).
set -euo pipefail

U=${SUDO_USER:-}
if [ "$(id -u)" -ne 0 ] || [ -z "$U" ] || [ "$U" = root ]; then
  echo "run with sudo from your normal user: sudo bash $0" >&2
  exit 1
fi
COMPOSE_VERSION=${COMPOSE_VERSION:-v5.8.0}
step() { printf '\n== %s\n' "$*"; }

step "Packages (container-tools:ol8, nodejs:22, EPEL for ripgrep/ShellCheck)"
dnf -y install oracle-epel-release-el8 dnf-plugins-core
dnf -y module enable container-tools:ol8
dnf -y module reset nodejs
dnf -y module enable nodejs:22
dnf -y install git make jq curl tar unzip which procps-ng ripgrep ShellCheck nodejs npm python3 \
  podman podman-docker buildah skopeo netavark aardvark-dns slirp4netns fuse-overlayfs containers-common
dnf -y distro-sync nodejs npm          # moves an already-installed older Node to the 22 stream
touch /etc/containers/nodocker         # silences podman-docker's "Emulate Docker CLI" notice
if rpm -q docker-ce moby-engine >/dev/null 2>&1; then
  echo "WARNING: Docker Engine is installed; remove it so only one engine runs containers" >&2
fi

step "newuidmap/newgidmap capabilities and sub-IDs for $U"
if ! getcap /usr/bin/newuidmap | grep -q cap_setuid; then rpm --setcaps shadow-utils; fi
getcap /usr/bin/newuidmap /usr/bin/newgidmap
grep -q "^$U:" /etc/subuid || usermod --add-subuids 100000-165535 "$U"
grep -q "^$U:" /etc/subgid || usermod --add-subgids 100000-165535 "$U"
grep "^$U:" /etc/subuid /etc/subgid

step "Docker Compose $COMPOSE_VERSION (SHA-256 checked)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
base="https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-x86_64"
curl -fsSL --retry 5 -o "$tmp/docker-compose" "$base"
curl -fsSL --retry 5 -o "$tmp/sum" "$base.sha256"
(cd "$tmp" && echo "$(cut -d' ' -f1 sum)  docker-compose" | sha256sum -c -)
install -m 0755 "$tmp/docker-compose" /usr/local/bin/docker-compose
mkdir -p /usr/local/lib/docker/cli-plugins
ln -sf /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose

step "cgroup controllers for user sessions, and lingering for $U"
mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' > /etc/systemd/system/user@.service.d/delegate.conf
systemctl daemon-reload
loginctl enable-linger "$U"

step "cgroups v2 (EL8 boots on v1)"
if [ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ]; then
  echo "already on cgroups v2"
else
  grubby --update-kernel=ALL --args=systemd.unified_cgroup_hierarchy=1
  echo "set; active after the reboot"
fi

printf '\nDone. Next: sudo reboot, then log in as %s directly (SSH or console, not su) and continue with\n' "$U"
printf 'section 3 of docs/podman-install-ol8.md.\n'
