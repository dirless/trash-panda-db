bin := "bin/raft_node_server"
src := "src/raft_node_server.cr"

# List available recipes
default:
    @just --list

# Run the full test suite
test:
    crystal spec --no-color

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

# Build the container image
build-image:
    podman build -t trash-panda-raft -f Containerfile .

# Build RPM for x86_64
rpm-x86:
    mkdir -p dist
    podman build --platform linux/amd64 -t trash-panda-rpm:x86_64 -f Containerfile.rpm .
    podman run --rm -v "$(pwd)/dist:/dist:z" trash-panda-rpm:x86_64 \
        sh -c 'cp /rpms/**/*.rpm /dist/'

# Build RPM for aarch64 (requires qemu-user-static on the host)
rpm-aarch64:
    mkdir -p dist
    podman build --platform linux/arm64 -t trash-panda-rpm:aarch64 -f Containerfile.rpm .
    podman run --rm -v "$(pwd)/dist:/dist:z" trash-panda-rpm:aarch64 \
        sh -c 'cp /rpms/**/*.rpm /dist/'

# Build RPMs for both architectures
rpm-all: rpm-x86 rpm-aarch64
