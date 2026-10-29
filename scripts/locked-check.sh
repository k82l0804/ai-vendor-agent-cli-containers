#!/usr/bin/env bash
# Verifies the locked profile's controls from inside each locked agent container, with no model calls.
# Usage: scripts/locked-check.sh [service...]      (default: every *-locked service)
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
compose=(docker compose --project-directory "$here" -f "$here/compose.yaml" -f "$here/compose.locked.yaml")
services=("$@")
[ ${#services[@]} -gt 0 ] || mapfile -t services < <("${compose[@]}" config --services | grep -- '-locked$' | sort)

# The real gateway key, read only to prove it never reaches an agent container.
key=$(grep -m1 -E '^(LOCKED_LLM_KEY|LITELLM_MASTER_KEY)=' "$here/.env" 2>/dev/null | cut -d= -f2- | tr -d '"')

"${compose[@]}" up -d --quiet-pull llm-gateway egress >/dev/null 2>&1
failed=0
for svc in "${services[@]}"; do
  echo "== $svc"
  out=$("${compose[@]}" run --rm -T --quiet-pull "$svc" bash -s < "$here/scripts/locked-check-inside.sh" 2>/dev/null)
  if [ -n "$key" ]; then
    env_dump=$("${compose[@]}" run --rm -T --quiet-pull "$svc" sh -c 'env; cat /proc/1/environ | tr "\0" "\n"' 2>/dev/null)
    if grep -qF -- "$key" <<<"$env_dump"; then out+=$'\nFAIL  the real model key is not in the container'; else out+=$'\nPASS  the real model key is not in the container'; fi
  fi
  echo "$out" | sed 's/^/  /'
  grep -q '^FAIL' <<<"$out" && failed=1
done
echo
echo "== egress proxy log (recent denials)"
docker logs --since 10m acp-egress 2>&1 | grep -E 'TCP_DENIED' | awk '{print "  " $4, $6, $7}' | sort | uniq -c | tail -10
[ $failed = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $failed
