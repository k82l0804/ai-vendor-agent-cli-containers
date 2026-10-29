ARG BASE=acp-base
FROM ${BASE}

USER root
RUN npm install -g opencode-ai \
 && npm cache clean --force
COPY setup.sh /etc/acp/setup.sh

USER agent
ENV ACP_AGENT=opencode
