# Produces a fully static binary via Alpine/musl.
# Use --platform to control target arch:
#   podman build --platform linux/amd64 -f Containerfile .
#   podman build --platform linux/arm64 -f Containerfile .

FROM docker.io/crystallang/crystal:latest-alpine AS builder
WORKDIR /build
RUN apk add --no-cache binutils pcre2-dev pcre2-static openssl-dev openssl-libs-static
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN crystal build src/trashpandadb.cr -o trashpandadb --release --no-debug --static \
    && strip trashpandadb

FROM scratch
COPY --from=builder /build/trashpandadb /trashpandadb
# 9001: Raft RPC   9002: client JSON API
EXPOSE 9001 9002
ENTRYPOINT ["/trashpandadb"]
