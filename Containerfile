# ── Build stage ───────────────────────────────────────────────────────────────
FROM crystallang/crystal:latest AS builder
WORKDIR /build
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN crystal build src/raft_node_server.cr -o bin/raft_node_server --release

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpcre2-8-0 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/bin/raft_node_server /app/raft_node_server
# 9001: Raft RPC   9002: client JSON API
EXPOSE 9001 9002
ENTRYPOINT ["/app/raft_node_server"]
