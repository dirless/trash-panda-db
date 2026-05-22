# ── Build stage ───────────────────────────────────────────────────────────────
FROM docker.io/crystallang/crystal:latest AS builder
WORKDIR /build
RUN mkdir -p bin
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN crystal build src/trashpandadb.cr -o bin/trashpandadb --release --no-debug

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpcre2-8-0 libssl3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/bin/trashpandadb /app/trashpandadb
# 9001: Raft RPC   9002: client JSON API
EXPOSE 9001 9002
ENTRYPOINT ["/app/trashpandadb"]
