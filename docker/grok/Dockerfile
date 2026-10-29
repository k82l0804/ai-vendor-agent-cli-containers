ARG BASE=acp-base
FROM ${BASE}

# xAI's installer downloads into $HOME/.grok/downloads and links into GROK_BIN_DIR; keep both outside the user's home,
# which acp-run replaces on every connection.
USER root
RUN mkdir -p /opt/grok \
 && curl -fsSL https://x.ai/cli/install.sh | HOME=/opt/grok GROK_BIN_DIR=/usr/local/bin bash \
 && chmod -R a+rX /opt/grok \
 && grok --version
COPY setup.sh /etc/acp/setup.sh

USER agent
ENV ACP_AGENT=grok
