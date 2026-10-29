ARG BASE=acp-base
FROM ${BASE}

# Google's Antigravity ACP server, latest version from the ACP registry, checked against the registry's SHA-256.
USER root
ARG REGISTRY=https://raw.githubusercontent.com/agentclientprotocol/registry/main/antigravity-acp/agent.json
RUN set -eu; \
    entry=$(curl -fsSL "$REGISTRY" | jq -c '.distribution.binary["linux-x86_64"]'); \
    url=$(echo "$entry" | jq -r .archive); sha=$(echo "$entry" | jq -r .sha256); \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -C - -o /tmp/agy.zip "$url"; \
    echo "$sha  /tmp/agy.zip" | sha256sum -c -; \
    mkdir -p /opt/agy && unzip -q /tmp/agy.zip -d /opt/agy && rm /tmp/agy.zip; \
    chmod -R a+rX /opt/agy; find /opt/agy -maxdepth 1 -type f -exec chmod 0755 {} +; \
    echo "$url" > /opt/agy/SOURCE
COPY setup.sh /etc/acp/setup.sh

USER agent
ENV ACP_AGENT=agy
