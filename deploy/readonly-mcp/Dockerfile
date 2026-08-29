FROM swift:6.3.1-noble AS build
ARG RETEX_REF=v0.8.0
WORKDIR /build
RUN git clone --filter=blob:none https://github.com/michael-berardi/retex.git . \
    && git checkout --detach "${RETEX_REF}"
RUN swift build -c release --product retex -j 2

FROM ubuntu:24.04
LABEL description="Retex read-only MCP — token-authenticated, curated knowledge only"
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip curl ca-certificates git \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir --break-system-packages \
      "fastmcp==2.12.5" "mcp==1.16.0"

COPY --from=build /build/.build/release/retex /usr/local/bin/retex
COPY --from=build /usr/lib/swift/linux /usr/lib/swift/linux
COPY --from=build /build/deploy/readonly-mcp/gateway.py /app/gateway.py
COPY --from=build /build/deploy/readonly-mcp/validate_vault.py /app/validate_vault.py
COPY knowledge /data/seed-vault
COPY --from=build /build/deploy/readonly-mcp/refresh_vault.py /app/refresh_vault.py

ENV LD_LIBRARY_PATH=/usr/lib/swift/linux \
    RETEX_BIN=/usr/local/bin/retex \
    RETEX_VAULT=/data/vault \
    RETEX_SEED_VAULT=/data/seed-vault \
    PORT=8080

# The baked vault is copied into the writable serving path at startup; when
# RETEX_VAULT_REPO is set the refresher swaps /data/vault atomically to
# freshly validated revisions.
# /data itself must be writable to publish new volumes; volume contents stay
# root-owned and read-only.
RUN python3 /app/validate_vault.py /data/seed-vault \
  && useradd -r -u 10001 retex \
  && mkdir -p /data/volumes \
  && chown retex:retex /data /data/volumes \
  && chmod -R a-w /data/seed-vault \
  && find /data/seed-vault -type d -exec chmod u+rwx {} + \
  && chmod a+rwx /data /data/volumes
USER retex

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -sf -H "Authorization: Bearer $RETEX_MCP_TOKEN" \
      http://127.0.0.1:${PORT}/health >/dev/null || exit 1
CMD ["python3", "/app/gateway.py"]
