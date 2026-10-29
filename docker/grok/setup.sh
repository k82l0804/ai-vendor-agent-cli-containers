# Sourced by acp-run. Auth: the host's ~/.grok/auth.json, mounted read-only at /creds/grok.
acp_setup() {
  [ -r /creds/grok/auth.json ] || { echo "acp-run: /creds/grok/auth.json missing (run 'grok login' on the host)" >&2; exit 1; }
  export GROK_HOME="$HOME/.grok"
  mkdir -p "$GROK_HOME"
  cp /creds/grok/auth.json "$GROK_HOME/auth.json"
  chmod 600 "$GROK_HOME/auth.json"
  cat > "$GROK_HOME/config.toml" <<'EOF'
[cli]
installer = "internal"
auto_update = false

[ui]
permission_mode = "always-approve"
EOF
  ACP_CMD=(grok agent --no-leader stdio)
}
