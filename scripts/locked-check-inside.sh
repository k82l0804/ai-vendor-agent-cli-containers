#!/usr/bin/env bash
# Runs inside one locked agent container (piped in by scripts/locked-check.sh). Prints one "PASS|FAIL <check>" line
# per control; never needs a model call.
set -u
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
refused() { local name=$1; shift; if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi; }
code() { curl --noproxy '*' -s -m 8 -o /dev/null -w '%{http_code}' "$@"; }

# Network: nothing but the gateway and the egress proxy.
refused "internet by name is unreachable (https://example.com)"        curl --noproxy '*' -s -m 8 https://example.com
refused "internet by IP is unreachable (http://1.1.1.1)"               curl --noproxy '*' -s -m 8 http://1.1.1.1
refused "outside DNS names do not resolve (example.com)"               getent hosts example.com
refused "the Docker host is unreachable (host.docker.internal:8000)"   curl --noproxy '*' -s -m 8 http://host.docker.internal:8000/
refused "the Docker host is unreachable (172.17.0.1:8000)"             curl --noproxy '*' -s -m 8 http://172.17.0.1:8000/
refused "egress proxy refuses a domain not on the allowlist"           curl -s -f -m 10 -x http://egress:3128 https://example.com
check   "model API reachable through llm-gateway with no key sent"     test "$(code http://llm-gateway:8000/v1/models)" = 200
check   "llm-gateway refuses non-model paths (/ui -> 403)"             test "$(code http://llm-gateway:8000/ui)" = 403

# Process and filesystem hardening.
check   "runs as a non-root user"                                      test "$(id -u)" != 0
check   "no Linux capabilities (CapEff = 0)"                           grep -q '^CapEff:[[:space:]]*0000000000000000$' /proc/self/status
check   "cannot gain privileges (NoNewPrivs = 1)"                      grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/self/status
refused "root filesystem is read-only"                                 touch /usr/local/.locked-check
refused "no Docker socket"                                             test -e /var/run/docker.sock
# Not host data: kernel filesystems, Docker's generated /etc files, the tmpfs, and the docker-init binary (init: true).
mounts=$(awk '$2 !~ "^/(proc|sys|dev)(/|$)" && $2 !~ "^/etc/(hosts|hostname|resolv.conf)$" && $2 != "/" && $2 != "/tmp" && $2 != "/usr/sbin/docker-init" {print $2}' /proc/mounts | sort -u | tr '\n' ' ')
check   "only the workspace is mounted from the host (${mounts% })"    test "${mounts% }" = "$WORKSPACE"
check   "process limit set (pids.max = $(cat /sys/fs/cgroup/pids.max 2>/dev/null))" test "$(cat /sys/fs/cgroup/pids.max 2>/dev/null)" != max

# The agent's own web tools: render the connection's config the way acp-run does, then look at it.
export HOME=$(mktemp -d /tmp/locked-check.XXXXXX) XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
XDG_CONFIG_HOME=$HOME/.config XDG_DATA_HOME=$HOME/.local/share XDG_STATE_HOME=$HOME/.local/state XDG_CACHE_HOME=$HOME/.cache
mkdir -p "$XDG_CONFIG_HOME"
# The subshell prints what acp_setup leaves in variables rather than files (agy's session options).
session_meta=$( { . /etc/acp/setup.sh && acp_setup; } >/dev/null 2>&1; printf '%s' "${ACP_SESSION_META:-}" )
case "${ACP_AGENT:-}" in
  opencode) check "web tools denied in opencode.json"  grep -q '"webfetch": "deny", "websearch": "deny"' "$XDG_CONFIG_HOME/opencode/opencode.json" ;;
  kilo)     check "web tools denied in kilo.jsonc"     grep -q '"webfetch": "deny", "websearch": "deny"' "$XDG_CONFIG_HOME/kilo/kilo.jsonc" ;;
  claude)   check "web tools denied in settings.json"  grep -q '"deny": \["WebFetch", "WebSearch"\]' "$HOME/.claude/settings.json" ;;
  codex)    check "web search disabled in codex config.toml" grep -q '^web_search = "disabled"' "$HOME/.codex/config.toml" ;;
  grok)     check "web tools denied in grok config.toml" grep -q '^deny = \["WebFetch", "WebSearch"\]' "$HOME/.grok/config.toml"
            check "grok web search and backend tools off" sh -c "grep -q '^disable_web_search = true' '$HOME/.grok/config.toml' && grep -q '^backend_tools = false' '$HOME/.grok/config.toml'" ;;
  agy)      if printf '%s' "$session_meta" | grep -qF '"disabledTools":["search_web","read_url_content"]'; then
              ok "agy sessions request search_web and read_url_content disabled"
            else
              bad "agy sessions request search_web and read_url_content disabled"
            fi ;;
  goose)    check "goose extensions limited to developer and todo"   test "$(grep -B3 'enabled: true' "$XDG_CONFIG_HOME/goose/config.yaml" | grep -o 'name: [a-z_]*' | tr '\n' ' ')" = "name: developer name: todo " ;;
esac
rm -rf "$HOME"
