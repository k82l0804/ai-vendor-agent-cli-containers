#!/usr/bin/env bash
# Copies the extra root CAs this host trusts (added by the site, not the distribution's own list) into
# docker/base/certs/ as PEM, so the images trust them too. For networks that inspect TLS with their own CA.
#   scripts/ca-from-host.sh [anchor-dir...]     default: the RHEL/OL and Debian/Ubuntu locations of site-added CAs
# Then: make rebuild
set -euo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
out="$here/docker/base/certs"
mkdir -p "$out"

dirs=("$@")
[ ${#dirs[@]} -gt 0 ] || dirs=(/etc/pki/ca-trust/source/anchors /usr/share/pki/ca-trust-source/anchors /usr/local/share/ca-certificates)

n=0
for d in "${dirs[@]}"; do
  [ -d "$d" ] || continue
  while IFS= read -r -d '' f; do
    name="host-$(basename "${f%.*}" | tr -c 'A-Za-z0-9._\n-' _).crt"
    if grep -q 'BEGIN CERTIFICATE' "$f"; then
      cp "$f" "$out/$name"
    elif openssl x509 -inform DER -in "$f" -out "$out/$name" 2>/dev/null; then
      :
    else
      echo "skipped (not a certificate): $f" >&2
      continue
    fi
    n=$((n + 1))
    echo "$f -> docker/base/certs/$name: $(openssl x509 -in "$out/$name" -noout -subject 2>/dev/null || echo '?')" >&2
  done < <(find "$d" -maxdepth 1 -type f -print0)
done

if [ "$n" -eq 0 ]; then
  echo "no site-added CAs found in: ${dirs[*]}" >&2
  echo "Ask your IT team for the root CA (PEM), put it in docker/base/certs/, then: make rebuild" >&2
  exit 1
fi
echo "$n CA file(s) in docker/base/certs/. Next: make rebuild" >&2
