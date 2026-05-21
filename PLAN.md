# TrashPandaDB — Investigation & Next Steps Plan

## Current state (commit 0fe1b6e)

All 533 specs pass. Raft snapshots implemented and verified in chaos tests.

### Implemented

- **Raft snapshots**: Leader periodically captures SQL state via pager DB file copy,
  truncates log to `snapshot_index`. Follower receives `InstallSnapshot` RPC when
  it falls behind `@log.base_index`. On restart, `apply_snapshot_if_present` restores
  DB state from snapshot, replays only suffix entries.
- **Pre-vote protocol**: PreVoteRequest/PreVoteReply, `request_pre_votes` collecting
  majority before real election. Prevents stale restarted nodes from winning elections.
- **Crash-safe persistence**: `fsync` after WAL commit, WAL checkpoint, Raft log persist.
- **Pager cache correctness**: `@cache.delete(page_no)` in `write_page` prevents stale
  cache hits after checkpoint overwrites pages.
- **Stale pager protection**: On restart without snapshot, `recreate_pager!` ensures
  clean btree state — no duplicate keys from stale pages.
- **Atomic snapshot writes**: tmp + rename for snapshot file, metadata, and log files.
- **Chaos test harness**: `--persistent` mode with podman volume mounts, configurable
  kill/restart intervals, settle-based convergence detection.

### Verified

- **Non-chaos persistent** (3 nodes, 120s, 20 writers): 4/4 tests converge
  (143546, 214587, 121105, 97589 rows — all nodes match)
- **Chaos persistent** (3 nodes, 60s, 10 writers, 5 kills): converges at 70787 rows
  all nodes after settle
- **Non-chaos in-memory** (9 nodes, 20 writers, 300s): converges cleanly
- **14 RaftNode specs**: all pass

---

## Open Issues

### 1. ~~Btree allows duplicate keys at storage layer~~ ✓ FIXED

`insert_into_leaf` now binary-searches the leaf page and raises
`Storage::DuplicateKeyError` if the key already exists. New btree spec covers
the case. (`btree.cr`, `spec/storage/btree_spec.cr`)

### 2. ~~No fsync on state/metadata files~~ ✓ FIXED

All metadata writes now use `File.open(tmp, "w") { |f| f.print(...); f.fsync }` +
`File.rename` + `fsync_dir`. Affected sites: `save_persistent_state`,
`take_snapshot` (meta + DB copy), `handle_install_snapshot` (meta + snap file),
`write_log_meta`, `copy_db_file`. (`raft_node.cr`, `raft_log.cr`, `database.cr`)

### 3. ~~fsync in hot write path throttles throughput~~ ✓ FIXED

Two changes:
- **Raft log `append_entries`**: moved `fsync` outside the per-entry loop so one
  `fsync` covers an entire AppendEntries batch instead of one per entry.
  (`write_to_file` + `sync_file` helpers; `persist` unchanged for single-entry paths.)
- **WAL `commit`**: changed `f.fsync` → `LibC.fdatasync(f.fd)`, which skips the
  metadata-only flush (mtime/ctime) while still ensuring data + size are durable.
  (`raft_log.cr`, `wal.cr`, `storage/constants.cr`)

### 4. ~~InstallSnapshot sends entire DB as base64 over TCP~~ ✓ FIXED

`InstallSnapshot` now carries an `offset : Int64` field.  The leader streams
the file in `SNAPSHOT_CHUNK_SIZE` (256 KB) chunks, one RPC per chunk, waiting
for a reply before sending the next.  The follower accumulates chunks into a
`.transfer` temp file keyed by `(last_included_index, offset)`; out-of-order
chunks return `success: false` so the leader restarts from chunk 0.  The
snapshot is applied (pager reload, metadata persist, log truncate) only when
`done=true` arrives.  (`messages.cr`, `raft_node.cr`,
`spec/replication/messages_spec.cr`)

### 5. Figure 8 edge case still possible if ALL nodes lose snapshot files simultaneously

Snapshots eliminate the §5.4.2 / Figure 8 data loss when at least one node survives
with its snapshot. But if ALL nodes in the committing quorum are killed before any
of them take a snapshot (first 2048 entries), committed entries are lost on restart.
Also, if persistent storage is lost (disk failure, container volume wipe), all
snapshots vanish simultaneously.

**Fix**: (a) Reduce `SNAPSHOT_INTERVAL` from 2048 to a lower value (e.g., 256)
for faster snapshot coverage in small tests. (b) Add WAL archiving to S3 or
a secondary volume for production deployments. (c) Document that the first
`SNAPSHOT_INTERVAL` entries after fresh start are vulnerable.