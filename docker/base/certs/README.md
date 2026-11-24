# Extra root CAs for the images

Only needed on a network that inspects TLS with its own CA (npm, curl or an agent fails with
`SELF_SIGNED_CERT_IN_CHAIN`, `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` or `unable to get local issuer certificate`).

Put the CA certificates here as PEM files (`*.crt` or `*.pem`; one or several certificates per file), or run
`make ca-certs` to copy the extra CAs this host trusts. Then `make rebuild` (the base image changes, so every agent
image is rebuilt). The files are git-ignored: they are site-specific.
