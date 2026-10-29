# Sourced by acp-run. Model: the local LiteLLM proxy, same provider shape as the host's ~/.config/kilo/kilo.jsonc.
acp_setup() {
  : "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY is not set (see .env)}"
  local model="${KILO_MODEL:-nemotron-3-ultra}"
  # Interpolated into the generated config below; refuse values it cannot carry.
  case "$model" in (*[!A-Za-z0-9._:/-]*) echo "acp-run: KILO_MODEL '$model' has characters the generated config cannot carry" >&2; exit 1;; esac
  # Locked profile (ACP_LOCKED=1): no web tools, and none of the background fetches a closed network refuses anyway.
  local web=allow
  if [ "${ACP_LOCKED:-}" = 1 ]; then
    web=deny
    export OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_DISABLE_DEFAULT_PLUGINS=1 \
           OPENCODE_DISABLE_AUTOUPDATE=1
  fi
  mkdir -p "$XDG_CONFIG_HOME/kilo"
  cat > "$XDG_CONFIG_HOME/kilo/kilo.jsonc" <<EOF
{
  "\$schema": "https://app.kilo.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "env": ["LITELLM_MASTER_KEY"],
      "options": { "baseURL": "${LLM_PROXY_URL:-http://llm-proxy:8000}/v1" },
      "models": { "${model}": { "name": "${model}" } }
    }
  },
  "model": "local/${model}",
  "permission": { "edit": "allow", "bash": "allow", "webfetch": "${web}", "websearch": "${web}", "external_directory": "allow" }
}
EOF
  ACP_CMD=(kilo acp --pure)
}
