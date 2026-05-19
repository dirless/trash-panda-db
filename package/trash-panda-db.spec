Name:           trash-panda-db
Version:        0.1.0
Release:        1%{?dist}
Summary:        Pure Crystal embedded SQL database with Raft replication
License:        MIT
URL:            https://github.com/dirless/trash-panda-db

# Binary is pre-built by the container build stage and placed in %%{_builddir}.
# No source tarball needed.
%global debug_package %{nil}

%description
TrashPandaDB is a pure Crystal embedded SQL database with Raft consensus
replication and crystal-db compatibility. No C bindings. No system library
dependencies beyond libpcre2.

The raft_node_server binary provides a standalone replicated cluster with a
JSON-over-TCP client API, follower-to-leader write forwarding, and DNS-based
peer discovery.

%install
install -Dm 0755 %{_builddir}/raft_node_server %{buildroot}%{_bindir}/raft_node_server

%files
%{_bindir}/raft_node_server

%changelog
* Mon May 18 2026 Lampros Chaidas <lampros.chaidas@gmail.com> - 0.1.0-1
- Initial package
