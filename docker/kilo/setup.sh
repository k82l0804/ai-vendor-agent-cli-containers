# Sourced by acp-run. Model: the local LiteLLM proxy, same provider shape as the host's ~/.config/kilo/kilo.jsonc.
acp_setup() {
  : "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY is not set (see .env)}"
  local model="${KILO_MODEL:-nemotron-3-ultra}"
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
  "permission": { "edit": "allow", "bash": "allow", "webfetch": "allow", "external_directory": "allow" }
}
EOF
  ACP_CMD=(kilo acp --pure)
}
