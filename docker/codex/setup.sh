# Sourced by acp-run. CODEX_AUTH picks the model source:
#   subscription: the host's ~/.codex/auth.json (from `codex login`), mounted read-only at /creds/codex.
#   proxy:        a custom model provider on the local LiteLLM proxy (OpenAI Responses API); no OpenAI login.
acp_setup() {
  export CODEX_HOME="$HOME/.codex"
  mkdir -p "$CODEX_HOME"
  local auth="${CODEX_AUTH:-subscription}" model="${CODEX_PROXY_MODEL:-nemotron-3-ultra}"
  case "$auth" in
    subscription)
      [ -r /creds/codex/auth.json ] || { echo "acp-run: /creds/codex/auth.json missing (run 'codex login' on the host)" >&2; exit 1; }
      cp /creds/codex/auth.json "$CODEX_HOME/auth.json"
      chmod 600 "$CODEX_HOME/auth.json"
      ;;
    proxy)
      : "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY is not set (see .env)}"
      # Interpolated into the generated TOML below; refuse values it cannot carry.
      case "$model" in (*[!A-Za-z0-9._:/-]*) echo "acp-run: CODEX_PROXY_MODEL '$model' has characters the generated config cannot carry" >&2; exit 1;; esac
      # Codex has no catalog entry for a proxy model, so it falls back to its default metadata (fine) and says so as
      # agent text at the start of every turn. A catalog entry would have to replace Codex's whole system prompt.
      ACP_DROP_MESSAGE='Warning: Model metadata for `[^`]*` not found\. Defaulting to fallback metadata;[^\n]*\s*'
      ;;
    *) echo "acp-run: CODEX_AUTH must be subscription or proxy" >&2; exit 1 ;;
  esac
  # codex's own sandbox cannot run inside Docker; the container is the sandbox.
  {
    cat <<'EOF'
approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false
EOF
    # Top-level keys must come before the first [table].
    if [ "$auth" = proxy ]; then
      cat <<EOF
model = "${model}"
model_provider = "llm-proxy"
EOF
    fi
    # Locked profile (ACP_LOCKED=1): no web search tool.
    if [ "${ACP_LOCKED:-}" = 1 ]; then echo 'web_search = "disabled"'; fi
    if [ "$auth" = proxy ]; then
      cat <<EOF

[model_providers.llm-proxy]
name = "LiteLLM proxy"
base_url = "${LLM_PROXY_URL:-http://llm-proxy:8000}/v1"
env_key = "LITELLM_MASTER_KEY"
wire_api = "responses"
EOF
    fi
    cat <<EOF

[history]
persistence = "none"

[analytics]
enabled = false

[projects."${WORKSPACE:-/}"]
trust_level = "trusted"
EOF
  } > "$CODEX_HOME/config.toml"
  # codex-acp starts sessions in "agent" (workspace-write, sandboxed by bubblewrap, which cannot run in Docker).
  ACP_INITIAL_MODE=agent-full-access
  ACP_CMD=(codex-acp)
}
