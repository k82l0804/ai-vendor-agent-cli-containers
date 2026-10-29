ARG BASE=acp-base
FROM ${BASE}

USER root
RUN npm install -g @kilocode/cli \
 && npm cache clean --force
COPY setup.sh /etc/acp/setup.sh

USER agent
ENV ACP_AGENT=kilo
