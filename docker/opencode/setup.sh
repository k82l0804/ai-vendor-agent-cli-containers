# Sourced by acp-run. Model: the local LiteLLM proxy (llm-proxy on the openai-proxy_default network).
acp_setup() {
  : "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY is not set (see .env)}"
  local model="${OPENCODE_MODEL:-nemotron-3-ultra}"
  export OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_SHARE=1
  # Locked profile (ACP_LOCKED=1): no web tools, and none of the background fetches a closed network refuses anyway.
  local web=allow
  if [ "${ACP_LOCKED:-}" = 1 ]; then
    web=deny
    export OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_DISABLE_DEFAULT_PLUGINS=1 \
           OPENCODE_DISABLE_AUTOUPDATE=1
  fi
  mkdir -p "$XDG_CONFIG_HOME/opencode"
  cat > "$XDG_CONFIG_HOME/opencode/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
  "provider": {
    "llm-proxy": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LiteLLM proxy",
      "options": { "baseURL": "${LLM_PROXY_URL:-http://llm-proxy:8000}/v1", "apiKey": "{env:LITELLM_MASTER_KEY}" },
      "models": { "${model}": { "name": "${model}" } }
    }
  },
  "model": "llm-proxy/${model}",
  "permission": { "edit": "allow", "bash": "allow", "webfetch": "${web}", "websearch": "${web}", "external_directory": "allow" }
}
EOF
  ACP_CMD=(opencode acp)
}
