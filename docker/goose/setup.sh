# Sourced by acp-run. Model: the local LiteLLM proxy through goose's OpenAI provider.
acp_setup() {
  : "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY is not set (see .env)}"
  export GOOSE_PROVIDER=openai \
         OPENAI_HOST="${LLM_PROXY_URL:-http://llm-proxy:8000}" \
         OPENAI_API_KEY="$LITELLM_MASTER_KEY" \
         GOOSE_MODEL="${GOOSE_MODEL:-nemotron-3-ultra}" \
         GOOSE_MODE=auto \
         GOOSE_DISABLE_KEYRING=1 \
         GOOSE_TELEMETRY_ENABLED=false
  mkdir -p "$XDG_CONFIG_HOME/goose"
  cat > "$XDG_CONFIG_HOME/goose/config.yaml" <<EOF
GOOSE_PROVIDER: openai
GOOSE_MODEL: ${GOOSE_MODEL}
GOOSE_MODE: auto
GOOSE_TELEMETRY_ENABLED: false
EOF
  ACP_CMD=(goose acp)
}
