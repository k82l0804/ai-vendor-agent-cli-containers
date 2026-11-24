FROM docker.io/library/node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq less procps ripgrep unzip \
 && rm -rf /var/lib/apt/lists/*

# The in-container user matches the host user, so files written to the workspace belong to them.
ARG UID=1000
ARG GID=1000
RUN userdel -r node 2>/dev/null || true \
 && groupadd -o -g "${GID}" agent \
 && useradd -o -m -u "${UID}" -g "${GID}" -s /bin/bash agent

# Extra root CAs, for networks that inspect TLS with their own CA (otherwise npm, curl and the agents fail with
# certificate errors). Put PEM files in docker/base/certs/ (git-ignored), or run `make ca-certs` to copy the host's.
# With no files there this changes nothing. The variables point Node, curl/OpenSSL and Python at the system bundle,
# which then includes the extra CAs; every agent image inherits them, for its build and at run time.
COPY certs/ /tmp/extra-ca/
RUN set -eu; n=0; \
    for f in /tmp/extra-ca/*.crt /tmp/extra-ca/*.pem; do \
      [ -f "$f" ] || continue; \
      grep -q 'BEGIN CERTIFICATE' "$f" || { echo "not a PEM certificate: $f" >&2; exit 1; }; \
      n=$((n + 1)); cp "$f" "/usr/local/share/ca-certificates/extra-$n.crt"; \
    done; \
    update-ca-certificates >/dev/null; rm -rf /tmp/extra-ca; echo "extra CA files: $n"
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NO_UPDATE_NOTIFIER=1 \
    DO_NOT_TRACK=1

COPY acp-run /usr/local/bin/acp-run
COPY acp-shim.mjs /usr/local/bin/acp-shim
RUN chmod 0755 /usr/local/bin/acp-run /usr/local/bin/acp-shim

USER agent
WORKDIR /home/agent
CMD ["sleep", "infinity"]
