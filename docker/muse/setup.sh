# Sourced by acp-run. Auth: the host's ~/.config/muse/auth.json (from `muse login`), mounted read-only at /creds/muse.
# Muse has no ACP mode; /opt/muse-acp/muse-acp.mjs bridges ACP to `muse serve`.
acp_setup() {
  [ -r /creds/muse/auth.json ] || { echo "acp-run: /creds/muse/auth.json missing (run 'muse login' on the host)" >&2; exit 1; }
  mkdir -p "$XDG_CONFIG_HOME/muse"
  cp /creds/muse/auth.json "$XDG_CONFIG_HOME/muse/auth.json"
  chmod 600 "$XDG_CONFIG_HOME/muse/auth.json"
  export MUSE_NO_AUTO_UPDATE=1
  ACP_CMD=(node /opt/muse-acp/muse-acp.mjs)
}
