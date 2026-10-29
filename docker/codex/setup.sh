# Sourced by acp-run. Auth: the host's ~/.codex/auth.json, mounted read-only at /creds/codex.
acp_setup() {
  [ -r /creds/codex/auth.json ] || { echo "acp-run: /creds/codex/auth.json missing (run 'codex login' on the host)" >&2; exit 1; }
  export CODEX_HOME="$HOME/.codex"
  mkdir -p "$CODEX_HOME"
  cp /creds/codex/auth.json "$CODEX_HOME/auth.json"
  chmod 600 "$CODEX_HOME/auth.json"
  # codex's own sandbox cannot run inside Docker; the container is the sandbox.
  cat > "$CODEX_HOME/config.toml" <<EOF
approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false

[history]
persistence = "none"

[analytics]
enabled = false

[projects."${WORKSPACE:-/}"]
trust_level = "trusted"
EOF
  # codex-acp starts sessions in "agent" (workspace-write, sandboxed by bubblewrap, which cannot run in Docker).
  ACP_INITIAL_MODE=agent-full-access
  ACP_CMD=(codex-acp)
}
