# Sourced by acp-run. CLAUDE_AUTH picks the model source:
#   subscription: CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`); nothing is copied from the host.
#   proxy:        the local LiteLLM proxy's Anthropic-format /v1/messages route; CLAUDE_PROXY_MODEL answers every
#                 request (main, subagents and the small background model).
acp_setup() {
  export DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_AUTOUPDATER=1 \
         CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
  case "${CLAUDE_AUTH:-subscription}" in
    subscription)
      : "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN is not set (see .env)}"
      ;;
    proxy)
      : "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY is not set (see .env)}"
      local model="${CLAUDE_PROXY_MODEL:-nemotron-3-ultra}"
      unset CLAUDE_CODE_OAUTH_TOKEN
      export ANTHROPIC_BASE_URL="${LLM_PROXY_URL:-http://llm-proxy:8000}" \
             ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY" \
             ANTHROPIC_MODEL="$model" \
             ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
             ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
             ANTHROPIC_DEFAULT_HAIKU_MODEL="$model" \
             CLAUDE_CODE_SUBAGENT_MODEL="$model" \
             CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
      ;;
    *) echo "acp-run: CLAUDE_AUTH must be subscription or proxy" >&2; exit 1 ;;
  esac
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude.json" <<'EOF'
{ "hasCompletedOnboarding": true, "bypassPermissionsModeAccepted": true }
EOF
  cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "permissions": { "defaultMode": "bypassPermissions" },
  "autoMemoryEnabled": false,
  "cleanupPeriodDays": 1
}
EOF
  ACP_CMD=(claude-agent-acp)
}
