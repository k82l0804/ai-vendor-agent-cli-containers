# Sourced by acp-run. AGY_AUTH picks the model source:
#   subscription: the host's Google sign-in (~/.gemini/antigravity-acp/acp_token.json), mounted read-only at /creds/agy.
#   proxy:        the local LiteLLM proxy through the Gemini-API route, as ~/workarea/fox/openai-proxy/scripts/agy-proxy.sh
#                 does for the agy CLI; LiteLLM's model_group_alias decides which model answers.
acp_setup() {
  local acp="$HOME/.gemini/antigravity-acp"
  mkdir -p "$acp"
  case "${AGY_AUTH:-subscription}" in
    subscription)
      [ -r /creds/agy/antigravity-acp/acp_token.json ] \
        || { echo "acp-run: /creds/agy/antigravity-acp/acp_token.json missing (sign in to Antigravity's ACP server on the host)" >&2; exit 1; }
      cp /creds/agy/antigravity-acp/acp_token.json "$acp/"
      chmod 600 "$acp/acp_token.json"
      echo '{ "auth": { "type": "oauth-personal" } }' > "$acp/settings.json"
      ;;
    proxy)
      : "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY is not set (see .env)}"
      export GEMINI_API_KEY="$LITELLM_MASTER_KEY" GOOGLE_GEMINI_BASE_URL="${LLM_PROXY_URL:-http://llm-proxy:8000}"
      echo '{ "auth": { "type": "gemini-api-key" } }' > "$acp/settings.json"
      ;;
    *) echo "acp-run: AGY_AUTH must be subscription or proxy" >&2; exit 1 ;;
  esac
  # New sessions always start in mode "default"; no setting changes that, so acp-shim switches to yolo.
  ACP_INITIAL_MODE=yolo
  # The harness writes its built-in skills to <session cwd>/skills/system before each turn, and nothing configures
  # that. Note whether the workspace had a skills folder, so acp_teardown removes only what agy left.
  [ -e "${WORKSPACE:-/nonexistent}/skills" ] && AGY_SKILLS_EXISTED=yes || AGY_SKILLS_EXISTED=no
  ACP_CMD=(/opt/agy/agy_acp_server.par --uid=)
}

acp_teardown() {
  local d="${WORKSPACE:-}/skills"
  [ -n "${WORKSPACE:-}" ] && [ "$AGY_SKILLS_EXISTED" = no ] && [ -d "$d" ] || return 0
  # Only skills/system/**/SKILL.md files marked `namespace: system`; anything else means it isn't ours to remove.
  [ -z "$(find "$d" -mindepth 1 -maxdepth 1 ! -name system)" ] || return 0
  [ -z "$(find "$d/system" -type f ! -name SKILL.md)" ] || return 0
  [ -z "$(find "$d/system" -type f -name SKILL.md -exec grep -L '^ *namespace: system' {} +)" ] || return 0
  rm -rf "$d"
}
