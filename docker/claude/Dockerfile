ARG BASE=acp-base
FROM ${BASE}

USER root
RUN npm install -g @anthropic-ai/claude-code @agentclientprotocol/claude-agent-acp \
 && npm cache clean --force
COPY setup.sh /etc/acp/setup.sh

USER agent
ENV ACP_AGENT=claude \
    CLAUDE_CODE_EXECUTABLE=/usr/local/bin/claude
