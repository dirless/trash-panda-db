# Runtime image for raft_node_server.
# Build the binary on the host first:
#   crystal build src/raft_node_server.cr -o bin/raft_node_server
# Then build the image:
#   podman build -t trash-panda-raft .

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpcre2-8-0 \
    && rm -rf /var/lib/apt/lists/*
COPY bin/raft_node_server /app/raft_node_server
RUN chmod +x /app/raft_node_server
# 9001: Raft RPC   9002: client JSON API
EXPOSE 9001 9002
ENTRYPOINT ["/app/raft_node_server"]
