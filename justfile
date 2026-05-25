bin     := "bin/trashpandadb"
hammer  := "bin/hammer"
src     := "src/trashpandadb.cr"
src_ham := "src/hammer.cr"

# Version is read from shard.yml — the single source of truth.
# Bump it there and everything else (RPM filename, release tag) picks it up.
version := `grep '^version:' shard.yml | sed 's/version: *//'`

# List available recipes
default:
    @just --list

# Run the full test suite
test:
    crystal spec --no-color

# Fast debug build (no-debug keeps symbols out of DWARF to speed up link)
build-dev:
    mkdir -p bin
    crystal build {{src}} -o {{bin}} --no-debug
    strip --strip-all {{bin}}

# Optimised release build
build:
    mkdir -p bin
    crystal build {{src}} -o {{bin}} --release --no-debug
    strip --strip-all {{bin}}

# Build the chaos/load testing tool
build-hammer:
    mkdir -p bin
    crystal build {{src_ham}} -o {{hammer}} --release --no-debug
    strip --strip-all {{hammer}}

# Release build and install to /usr/local/bin (requires sudo)
install: build
    sudo install -m 755 {{bin}} /usr/local/bin/trashpandadb

# Build the container image
build-image:
    podman build -t trash-panda-raft -f Containerfile .

# Build RPM for x86_64
rpm-x86:
    mkdir -p dist
    podman build --platform linux/amd64 --build-arg VERSION={{version}} \
        -t trash-panda-rpm:x86_64 -f Containerfile.rpm .
    podman run --rm -v "$(pwd)/dist:/dist:z" trash-panda-rpm:x86_64 \
        sh -c 'cp /rpms/**/*.rpm /dist/'

# Build RPM for aarch64 (requires qemu-user-static on the host)
rpm-aarch64:
    mkdir -p dist
    podman build --platform linux/arm64 --build-arg VERSION={{version}} \
        -t trash-panda-rpm:aarch64 -f Containerfile.rpm .
    podman run --rm -v "$(pwd)/dist:/dist:z" trash-panda-rpm:aarch64 \
        sh -c 'cp /rpms/**/*.rpm /dist/'

# Build RPMs for both architectures
rpm-all: rpm-x86 rpm-aarch64

# Tag, push, and create GitHub release with the x86_64 RPM
release: rpm-x86
    git tag v{{version}}
    git push origin main --tags
    gh release create v{{version}} dist/trash-panda-db-{{version}}-1.x86_64.rpm \
        --title "v{{version}}" \
        --notes "See changelog in package/trash-panda-db.spec."
