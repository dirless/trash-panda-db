Name:           trash-panda-db
Version:        0.5.0
Release:        1
Summary:        Pure Crystal embedded SQL database with Raft replication
License:        MIT
URL:            https://github.com/dirless/trash-panda-db

BuildRequires:  systemd-rpm-macros
Requires:       pcre2
Requires(pre):  shadow-utils
%global debug_package %{nil}

%description
TrashPandaDB is a pure Crystal embedded SQL database with Raft consensus
replication and crystal-db compatibility. No C bindings. No system library
dependencies beyond libpcre2.

The trashpandadb binary provides a standalone replicated cluster with a
JSON-over-TCP client API, follower-to-leader write forwarding, and DNS-based
peer discovery.

%pre
getent group trashpandadb >/dev/null || groupadd -r trashpandadb
getent passwd trashpandadb >/dev/null || \
    useradd -r -g trashpandadb -d /var/lib/trashpandadb -s /sbin/nologin \
            -c "TrashPandaDB service account" trashpandadb
exit 0

%install
mkdir -p %{buildroot}%{_bindir}
mkdir -p %{buildroot}%{_unitdir}
mkdir -p %{buildroot}%{_sysconfdir}/trashpandadb
mkdir -p %{buildroot}%{_sharedstatedir}/trashpandadb

install -m 0755 /tmp/trashpandadb        %{buildroot}%{_bindir}/trashpandadb
install -m 0644 /tmp/package/trashpandadb.service %{buildroot}%{_unitdir}/trashpandadb.service
install -m 0640 /tmp/package/trashpandadb.env     %{buildroot}%{_sysconfdir}/trashpandadb/env

%post
%systemd_post trashpandadb.service

%preun
%systemd_preun trashpandadb.service

%postun
%systemd_postun_with_restart trashpandadb.service

%files
%{_bindir}/trashpandadb
%{_unitdir}/trashpandadb.service
%config(noreplace) %{_sysconfdir}/trashpandadb/env
%attr(0750, trashpandadb, trashpandadb) %dir %{_sharedstatedir}/trashpandadb

%changelog
* Wed May 21 2026 Lampros Chaidas <info@dirless.com> - 0.5.0-1
- SELECT DISTINCT support (full table scan, JOIN, subquery, ORDER BY, LIMIT)
- Raft §8 read-index protocol: query() now confirms quorum before serving reads
- Fix 10 correctness/safety bugs: socket leak, propose deadlock, TOCTOU in
  snapshot sender, stuck config flag, silent state loss, @mu held during
  snapshot I/O, unbounded replication fibers, pre-vote data race, pending
  channel drain on stop, in-memory pager FD leak
- Collapse triple @mu reads in start_election/request_pre_votes
- 544 specs, 0 failures

* Mon May 19 2026 Lampros Chaidas <info@dirless.com> - 0.4.0-1
- Transparent cluster membership changes via --join ADDR flag
- New client API action: join (admits a new node, forwarded to leader)
- status response now includes members object with raft/client addrs
- 418 specs, 0 failures

* Mon May 19 2026 Lampros Chaidas <info@dirless.com> - 0.2.0-1
- Add systemd unit, trashpandadb system user, and /etc/trashpandadb/env config
- Rename --dns-cluster-size to --dns-minimum-cluster-size; now accepts >= N nodes
- Strip debug info from binary (--no-debug + strip)

* Mon May 18 2026 Lampros Chaidas <info@dirless.com> - 0.1.0-1
- Initial package
