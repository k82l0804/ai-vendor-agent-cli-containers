ARG BASE=acp-base
FROM ${BASE}

# Meta's installer puts a launcher in MUSE_INSTALL_DIR; its first run downloads the real binary beside it. Do that at
# build time (the launcher doesn't update itself at runtime: MUSE_NO_AUTO_UPDATE=1), then install the SDK version that
# matches it for the ACP adapter.
USER root
ENV MUSE_NO_AUTO_UPDATE=1
RUN mkdir -p /opt/muse \
 && curl -fsSL https://dev.meta.ai/install.sh | HOME=/root MUSE_INSTALL_DIR=/opt/muse bash \
 && ln -s /opt/muse/muse /usr/local/bin/muse \
 && HOME=/root MUSE_NO_AUTO_UPDATE=0 muse --version \
 && chmod -R a+rX /opt/muse
COPY muse-acp.mjs /opt/muse-acp/muse-acp.mjs
RUN cd /opt/muse-acp \
 && v=$(muse --version | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+' | head -1) \
 && echo '{ "name": "muse-acp", "private": true, "type": "module" }' > package.json \
 && npm install --omit=dev "@muse-code/sdk@$v" \
 && npm cache clean --force
COPY setup.sh /etc/acp/setup.sh

USER agent
ENV ACP_AGENT=muse
