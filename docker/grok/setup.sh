# Sourced by acp-run. GROK_AUTH picks the model source:
#   subscription: the host's ~/.grok/auth.json (from `grok login`), mounted read-only at /creds/grok.
#   proxy:        a custom model on the local LiteLLM proxy (OpenAI chat completions); no xAI login.
acp_setup() {
  export GROK_HOME="$HOME/.grok"
  mkdir -p "$GROK_HOME"
  local auth="${GROK_AUTH:-subscription}" model="${GROK_PROXY_MODEL:-nemotron-3-ultra}" ctx="${GROK_PROXY_CONTEXT_WINDOW:-128000}"
  case "$auth" in
    subscription)
      [ -r /creds/grok/auth.json ] || { echo "acp-run: /creds/grok/auth.json missing (run 'grok login' on the host)" >&2; exit 1; }
      cp /creds/grok/auth.json "$GROK_HOME/auth.json"
      chmod 600 "$GROK_HOME/auth.json"
      ;;
    proxy)
      : "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY is not set (see .env)}"
      # Both are interpolated into the generated TOML below; refuse values it cannot carry.
      case "$model" in (*[!A-Za-z0-9._:/-]*) echo "acp-run: GROK_PROXY_MODEL '$model' has characters the generated config cannot carry" >&2; exit 1;; esac
      case "$ctx" in (''|*[!0-9]*) echo "acp-run: GROK_PROXY_CONTEXT_WINDOW '$ctx' is not a whole number" >&2; exit 1;; esac
      ;;
    *) echo "acp-run: GROK_AUTH must be subscription or proxy" >&2; exit 1 ;;
  esac
  # Locked profile (ACP_LOCKED=1): no web tools, no background fetches or telemetry.
  {
    # Top-level keys must come before the first [table].
    if [ "${ACP_LOCKED:-}" = 1 ]; then echo 'disable_web_search = true'; fi
    cat <<'EOF'
[cli]
installer = "internal"
auto_update = false

[ui]
permission_mode = "always-approve"
EOF
    if [ "$auth" = proxy ]; then
      cat <<EOF

[models]
default = "llm-proxy"

[model.llm-proxy]
model = "${model}"
name = "${model} (LiteLLM proxy)"
base_url = "${LLM_PROXY_URL:-http://llm-proxy:8000}/v1"
env_key = "LITELLM_MASTER_KEY"
api_backend = "chat_completions"
context_window = ${ctx}
EOF
    fi
    if [ "${ACP_LOCKED:-}" = 1 ]; then
      cat <<'EOF'

[features]
backend_tools = false
telemetry = "off"
remote_fetch = false
managed_config = false
campaigns = false

[permission]
deny = ["WebFetch", "WebSearch"]
EOF
    fi
  } > "$GROK_HOME/config.toml"
  ACP_CMD=(grok agent --no-leader stdio)
}
