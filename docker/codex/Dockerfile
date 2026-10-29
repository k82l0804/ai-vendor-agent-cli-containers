ARG BASE=acp-base
FROM ${BASE}

USER root
RUN npm install -g @openai/codex @agentclientprotocol/codex-acp \
 && npm cache clean --force
COPY setup.sh /etc/acp/setup.sh

USER agent
ENV ACP_AGENT=codex
