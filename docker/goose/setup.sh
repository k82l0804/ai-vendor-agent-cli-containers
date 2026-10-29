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
  # Locked profile (ACP_LOCKED=1): only the developer (files, shell) and todo extensions. The others include skills
  # with a web search (summon), apps, and an extension manager that could turn extensions back on.
  if [ "${ACP_LOCKED:-}" = 1 ]; then
    echo "extensions:" >> "$XDG_CONFIG_HOME/goose/config.yaml"
    local ext on
    for ext in developer todo analyze apps chatrecall code_execution extensionmanager javascript scheduler summarize summon tom; do
      case $ext in developer|todo) on=true ;; *) on=false ;; esac
      printf '  %s:\n    name: %s\n    type: platform\n    enabled: %s\n' "$ext" "$ext" "$on" >> "$XDG_CONFIG_HOME/goose/config.yaml"
    done
  fi
  ACP_CMD=(goose acp)
}
