FROM swift:6.3.1-noble AS build
ARG RETEX_REF=v0.4.2
WORKDIR /build
RUN git clone --filter=blob:none https://github.com/michael-berardi/retex.git . \
    && git checkout --detach "${RETEX_REF}"
RUN swift build -c release --product retex -j 2

FROM ubuntu:24.04
LABEL description="Retex read-only MCP — token-authenticated, curated knowledge only"
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir --break-system-packages \
      "fastmcp==2.12.*" "mcp>=1.12,<1.17"

COPY --from=build /build/.build/release/retex /usr/local/bin/retex
COPY --from=build /usr/lib/swift/linux /usr/local/lib/swift
COPY --from=build /build/deploy/readonly-mcp/gateway.py /app/gateway.py
COPY --from=build /build/deploy/readonly-mcp/validate_vault.py /app/validate_vault.py
COPY knowledge /data/vault

ENV LD_LIBRARY_PATH=/usr/local/lib/swift \
    RETEX_BIN=/usr/local/bin/retex \
    RETEX_VAULT=/data/vault \
    PORT=8080

RUN python3 /app/validate_vault.py /data/vault \
    && useradd -r -u 10001 retex \
    && chown -R root:root /data/vault \
    && chmod -R a-w /data/vault
USER retex

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -sf -H "Authorization: Bearer $RETEX_MCP_TOKEN" \
      http://127.0.0.1:${PORT}/health >/dev/null || exit 1
CMD ["python3", "/app/gateway.py"]
