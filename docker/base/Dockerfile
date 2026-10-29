FROM node:22-bookworm-slim

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

ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NO_UPDATE_NOTIFIER=1 \
    DO_NOT_TRACK=1

COPY acp-run /usr/local/bin/acp-run
COPY acp-shim.mjs /usr/local/bin/acp-shim
RUN chmod 0755 /usr/local/bin/acp-run /usr/local/bin/acp-shim

USER agent
WORKDIR /home/agent
CMD ["sleep", "infinity"]
