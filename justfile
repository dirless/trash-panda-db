bin := "bin/raft_node_server"
src := "src/raft_node_server.cr"

# Fast debug build
build-dev:
    mkdir -p bin
    crystal build {{src}} -o {{bin}}

# Optimised release build
build:
    mkdir -p bin
    crystal build {{src}} -o {{bin}} --release

# Release build and install to /usr/local/bin (requires sudo)
install: build
    sudo install -m 755 {{bin}} /usr/local/bin/raft_node_server
