ARG BASE=acp-base
FROM ${BASE}

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends bzip2 libdbus-1-3 libxcb1 \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh \
    | GOOSE_BIN_DIR=/usr/local/bin CONFIGURE=false bash \
 && goose --version
COPY setup.sh /etc/acp/setup.sh

USER agent
ENV ACP_AGENT=goose
