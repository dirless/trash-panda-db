# TrashPandaDB

A pure Crystal embedded SQL database with Raft replication and [crystal-db](https://github.com/crystal-lang/crystal-db) compatibility.

- No C bindings
- No system library dependencies (beyond libpcre2 for Crystal itself)
- Embedded use via `crystal-db` driver, or standalone replicated cluster via TCP

---

## Table of Contents

- [Embedded Use](#embedded-use)
- [SQL Support](#sql-support)
- [Storage](#storage)
- [Raft Replication](#raft-replication)
  - [Standalone Server](#standalone-server)
  - [Peer Discovery](#peer-discovery)
  - [DNS Peer Discovery](#dns-peer-discovery)
  - [Expanding the Cluster](#expanding-the-cluster)
  - [Durability Guarantees](#durability-guarantees)
  - [Manual Snapshot Backup](#manual-snapshot-backup)
  - [Client API](#client-api)
- [Installing](#installing)
- [Building](#building)
- [Testing](#testing)

---

## Embedded Use

Add to `shard.yml`:

```yaml
dependencies:
  trash-panda-db:
    github: your-org/trash-panda-db
    version: "~> 0.4"
```

```crystal
require "trash-panda-db"

DB.open("trashpanda:/path/to/data.tpdb") do |db|
  db.exec "CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)"
  db.exec "INSERT INTO kv VALUES (?, ?)", "hello", "world"
  db.query_one "SELECT v FROM kv WHERE k = ?", "hello", as: String  # => "world"
end

# In-memory (no persistence)
DB.open("trashpanda::memory:") { |db| ... }
```

All `crystal-db` patterns work: connection pools, transactions, prepared statements, `query_one`, `query_all`, etc.

---

## SQL Support

| Feature | Supported |
|---|---|
| `CREATE TABLE`, `DROP TABLE` | Yes |
| `INSERT`, `UPDATE`, `DELETE` | Yes |
| `SELECT` with `WHERE`, `ORDER BY`, `LIMIT`, `OFFSET` | Yes |
| `JOIN` (INNER, LEFT, CROSS), table aliases | Yes |
| `GROUP BY`, `HAVING` | Yes |
| Aggregate functions (`COUNT`, `SUM`, `AVG`, `MIN`, `MAX`) | Yes |
| Subqueries (`FROM (SELECT ...)`, scalar, `EXISTS`) | Yes |
| `ON CONFLICT DO UPDATE SET` (upsert), `excluded.*` | Yes |
| `CREATE [UNIQUE] INDEX`, multi-column indexes | Yes |
| `BEGIN` / `COMMIT` / `ROLLBACK` | Yes |
| `SAVEPOINT` / `RELEASE` / `ROLLBACK TO SAVEPOINT` | Yes |
| `PRIMARY KEY`, `NOT NULL`, `UNIQUE`, `DEFAULT` | Yes |
| `CAST`, `LIKE`, `IN`, `IS NULL`, `BETWEEN` | Yes |
| `REGEXP` | Yes |
| `VACUUM` | Yes |
| `PRAGMA` (accepted as no-ops) | Yes |
| Qualified star (`t.*` in JOINs) | Yes |
| Parameter binding (`?`) | Yes |

Value types: `NULL`, `INTEGER` (Int64), `REAL` (Float64), `TEXT`, `BLOB`.

---

## Storage

- **Page-based**: 4 KB pages. Database header occupies page 0.
- **B+ tree**: each table and index is backed by its own B+ tree rooted at a catalog-tracked page. Rows are encoded with a compact binary format (big-endian Int64 keys for sort order).
- **WAL**: writes go to a `-wal` file first. Auto-checkpointed to the main file when ≥ 64 dirty pages accumulate.
- **Multi-page catalog**: table schemas, B+ tree roots, and index metadata span as many 4 KB catalog pages as needed.
- **Crash recovery**: WAL is replayed on open. A clean checkpoint removes the WAL file.

### Record size

There is no hard per-record size limit. Practical constraints:

- **In replicated mode**, each write's SQL is stored verbatim in the Raft log. A large `INSERT` produces a proportionally large log entry.

TrashPandaDB is designed for structured relational data — not a blob store. For large binary objects, store a path or reference in TrashPandaDB and keep the data elsewhere.

---

## Raft Replication

TrashPandaDB ships a standalone server binary that runs a Raft node, exposes a JSON-over-TCP client API, and transparently forwards writes from followers to the leader.

### Standalone Server

Build the binary on the host (requires Crystal ≥ 1.20):

```bash
crystal build src/trashpandadb.cr -o bin/trashpandadb
```

Build the container image (binary must exist first):

```bash
podman build -t trash-panda-raft -f Containerfile .
# or: docker build -t trash-panda-raft -f Containerfile .
```

### Peer Discovery

**Explicit peers** — specify each peer's Raft and client address manually:

```bash
podman run trash-panda-raft \
  --node-id n1 \
  --raft   0.0.0.0:9001 \
  --client 0.0.0.0:9002 \
  --peer n2=db2.internal:9001  --peer n3=db3.internal:9001 \
  --client-peer n2=db2.internal:9002  --client-peer n3=db3.internal:9002
```

### DNS Peer Discovery

Point `--dns-peers` at a DNS name whose **A record lists every node's IP**. Each container resolves the record at startup, excludes its own IP, and wires up the remaining IPs as peers. The node ID is set automatically to the container's own IP.

```bash
podman run trash-panda-raft \
  --raft   0.0.0.0:9001 \
  --client 0.0.0.0:9002 \
  --dns-peers db-cluster.example.com
```

**Cluster-size guard**: by default the server refuses to start unless the A record resolves to at least **3** IPs. More nodes are fine. Change the minimum with `--dns-minimum-cluster-size N`:

```
ERROR: --dns-minimum-cluster-size is 3 but 'db-cluster.example.com' resolved to only 2 addresses (10.0.0.1, 10.0.0.2).
Update the DNS record or lower --dns-minimum-cluster-size.
```

This means scaling the cluster up is as simple as adding IPs to the DNS record and restarting nodes with an updated `--dns-minimum-cluster-size`.

**DNS options:**

| Flag | Default | Description |
|---|---|---|
| `--dns-peers HOSTNAME` | — | DNS A-record hostname for peer discovery |
| `--dns-raft-port PORT` | `9001` | Raft RPC port for discovered peers |
| `--dns-client-port PORT` | `9002` | Client API port for discovered peers |
| `--dns-minimum-cluster-size N` | `3` | Minimum node count required; startup fails if the A record resolves to fewer IPs |

**Example with Podman (`--add-host` simulates a multi-A DNS record):**

```bash
podman network create --subnet 10.91.0.0/24 raft-demo

HOSTS="--add-host raft-cluster:10.91.0.11 --add-host raft-cluster:10.91.0.12 --add-host raft-cluster:10.91.0.13"

for i in 1 2 3; do
  ip="10.91.0.1${i}"
  podman run -d --name raft-n${i} --network raft-demo --ip $ip \
    $HOSTS -p 1900${i}:9002 trash-panda-raft \
    --raft 0.0.0.0:9001 --client 0.0.0.0:9002 \
    --dns-peers raft-cluster
done
```

### Expanding the Cluster

TrashPandaDB supports **transparent single-server membership changes** — add one node at a time, safely, without downtime.

To add a fourth node to a running 3-node cluster:

```bash
trashpandadb \
  --node-id n4 \
  --raft   0.0.0.0:9001 \
  --client 0.0.0.0:9002 \
  --join   n1.internal:9002 \
  --data-dir /var/lib/trashpandadb
```

`--join` points at the **client port** of any existing cluster node. The new node:

1. Starts with elections suppressed (it has no peers yet)
2. Sends a `join` request — forwarded to the current leader automatically
3. The leader commits an `add` log entry (replicated to a quorum of existing members)
4. Once committed, the new node enables elections and begins participating normally

**Going from 3 → 5 nodes**: start n4 with `--join`, wait for it to join, then start n5 with `--join`. Each change is committed one at a time. Only one membership change may be in flight at once; a second concurrent `--join` retries automatically until the first commits.

**Safety**: quorum overlap is guaranteed because only one node is added at a time, so the old and new majorities always share at least one member. A 3→5 expansion goes 3→4→5 internally, never risking a split-brain.

### Durability guarantees

**What is always durable (survives a single-node crash):**

- Each Raft log entry is `fsync`-ed before the leader counts it toward the commit quorum and before a follower acknowledges it. A committed entry is safe on a majority of nodes.
- Applied SQL is flushed from the WAL to the main DB file every 200 applied entries (`APPLY_FLUSH_INTERVAL`). At most 200 entries' worth of SQL state can be in the WAL-only at any given time.
- Snapshots are taken by the leader every 256 committed entries (`SNAPSHOT_INTERVAL`). Once a snapshot exists, the Raft log up to that index is truncated; the snapshot file alone is sufficient to restore the node.
- All metadata files (`raft_state.json`, `raft_snapshot.json`, `raft_log_meta.json`) are written with `fsync` + atomic rename + parent-directory `fsync`, so a crash during a write never leaves a partial file.
- Snapshot chunks sent via `InstallSnapshot` are assembled into a `.transfer` temp file and `fsync`-ed before the pager is replaced, so an interrupted transfer leaves the existing snapshot intact.

**The vulnerability window:**

The first `SNAPSHOT_INTERVAL` (256) committed entries after a fresh cluster start — indices 1 through 255 — are not yet covered by a snapshot. If **all** nodes in a committing quorum simultaneously lose both their Raft log file **and** their data directory (e.g. disk failure or volume wipe), those entries are permanently unrecoverable. After entry 256 the leader takes its first snapshot, and from that point forward a single surviving node with its data directory intact is sufficient to reconstruct the cluster.

This is the §5.4.2 / Figure 8 scenario from the Raft paper. Normal single-node failures and restarts — the common case — are fully safe: the Raft log on the surviving majority re-applies any missing entries.

**Production hardening (not built-in):**

For environments where simultaneous volume loss is a realistic risk, archive the `--data-dir` to object storage (e.g. S3, GCS) or a separate volume. The `raft_snapshot.db` + `raft_snapshot.json` files together are a self-contained restore point; the `raft_log.jsonl` is needed only for entries since the last snapshot.

### Manual Snapshot Backup

TrashPandaDB automatically takes a snapshot every 256 committed entries
(`SNAPSHOT_INTERVAL`). A snapshot is a self-contained copy of the database at a
specific Raft index. Backing it up gives you an offline restore point independent of
the Raft log.

#### Files in `--data-dir`

| File | Description |
|------|-------------|
| `data.db` | Live SQLite-style page file (the pager's main DB) |
| `data.db-wal` | Write-ahead log (may be empty after a checkpoint) |
| `raft_snapshot.db` | Latest snapshot — a checkpointed copy of `data.db` |
| `raft_snapshot.json` | Snapshot metadata: `last_included_index`, `last_included_term` |
| `raft_log.jsonl` | Log entries appended after the last snapshot |
| `raft_log_meta.json` | Log base index/term (snapshot boundary) |
| `raft_state.json` | Durable Raft state: `current_term`, `voted_for`, `commit_index` |

A complete restore point consists of `raft_snapshot.db` + `raft_snapshot.json`.
`raft_log.jsonl` covers the gap between the snapshot and the current commit index; include it for a more recent restore point.

#### Taking a backup

Snapshots are written with an atomic rename so the file is always complete on disk.
Copy `raft_snapshot.db` and `raft_snapshot.json` at any time while the server is
running — no shutdown required:

```bash
DATA_DIR=/var/lib/trashpandadb
BACKUP_DIR=/mnt/backups/trashpanda-$(date +%Y%m%dT%H%M%S)

mkdir -p "$BACKUP_DIR"

# Core snapshot (self-contained restore point)
cp "$DATA_DIR/raft_snapshot.db"   "$BACKUP_DIR/"
cp "$DATA_DIR/raft_snapshot.json" "$BACKUP_DIR/"

# Optional: include post-snapshot log entries for a more recent restore point
cp "$DATA_DIR/raft_log.jsonl"     "$BACKUP_DIR/"
cp "$DATA_DIR/raft_log_meta.json" "$BACKUP_DIR/"
cp "$DATA_DIR/raft_state.json"    "$BACKUP_DIR/"

echo "Backed up to $BACKUP_DIR"
cat "$BACKUP_DIR/raft_snapshot.json"
# → {"last_included_index":512,"last_included_term":3}
```

You can verify which Raft index the snapshot covers before archiving it:

```bash
jq .last_included_index /var/lib/trashpandadb/raft_snapshot.json
```

If no snapshot has been taken yet (fewer than 256 committed entries), `raft_snapshot.db`
will not exist. In that case back up the live database and the full log:

```bash
# Fallback when no snapshot exists yet
cp "$DATA_DIR/data.db"            "$BACKUP_DIR/"
cp "$DATA_DIR/data.db-wal"        "$BACKUP_DIR/" 2>/dev/null || true
cp "$DATA_DIR/raft_log.jsonl"     "$BACKUP_DIR/"
cp "$DATA_DIR/raft_log_meta.json" "$BACKUP_DIR/"
cp "$DATA_DIR/raft_state.json"    "$BACKUP_DIR/"
```

#### Restoring from a backup

Restoring replaces one node's data directory with the backup. The node will
catch up any entries committed after the snapshot index via normal Raft replication
when it rejoins.

```bash
NODE=n1
DATA_DIR=/var/lib/trashpandadb
BACKUP_DIR=/mnt/backups/trashpanda-20260521T120000

# 1. Stop the node
systemctl stop trashpandadb   # or kill the process

# 2. Wipe the stale data directory
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

# 3. Restore snapshot files
cp "$BACKUP_DIR/raft_snapshot.db"   "$DATA_DIR/"
cp "$BACKUP_DIR/raft_snapshot.json" "$DATA_DIR/"

# 4. Optionally restore log files (skip to let the cluster replay from scratch)
cp "$BACKUP_DIR/raft_log.jsonl"     "$DATA_DIR/" 2>/dev/null || true
cp "$BACKUP_DIR/raft_log_meta.json" "$DATA_DIR/" 2>/dev/null || true
cp "$BACKUP_DIR/raft_state.json"    "$DATA_DIR/" 2>/dev/null || true

# 5. Restart — the node will apply the snapshot on startup, then receive
#    any missing entries from the leader via AppendEntries or InstallSnapshot.
systemctl start trashpandadb
```

> **Tip:** For automated off-site backups, schedule the copy script above with
> `cron` or a systemd timer and ship the output directory to object storage
> (S3, GCS, etc.). Because the snapshot file is written atomically, the copy
> is always consistent even if it races with an in-progress snapshot rotation.

### Client API

Each node listens on a TCP client port (default 9002). Send one JSON line per connection; the response is one JSON line.

**status**
```json
{"action":"status"}
// → {"ok":true,"role":"Leader","node_id":"n1","leader_id":"n1","term":2,
//    "members":{"n1":{"raft":"10.0.0.1:9001","client":"10.0.0.1:9002"},...}}
```

**join** — add a new node to the cluster (forwarded to the leader automatically)
```json
{"action":"join","node_id":"n4","raft_addr":"10.0.0.4:9001","client_addr":"10.0.0.4:9002"}
// → {"ok":true}
```

**propose** — write (any node; followers forward to leader transparently)
```json
{"action":"propose","sql":"INSERT INTO kv VALUES ('k','v')"}
// → {"ok":true,"rows_affected":1,"last_id":1}
```

**query** — linearisable read (leader only)
```json
{"action":"query","sql":"SELECT v FROM kv WHERE k = 'k'"}
// → {"ok":true,"cols":["v"],"rows":[["v"]]}
```

**local_query** — read from local state machine (any node; may be slightly behind)
```json
{"action":"local_query","sql":"SELECT * FROM kv"}
// → {"ok":true,"cols":["k","v"],"rows":[["k","v"]]}
```

**Quick test with netcat:**
```bash
echo '{"action":"propose","sql":"CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"}' | nc -q1 127.0.0.1 19001
echo '{"action":"propose","sql":"INSERT INTO t VALUES (1, '\''hello'\'')"}' | nc -q1 127.0.0.1 19002
echo '{"action":"local_query","sql":"SELECT * FROM t"}' | nc -q1 127.0.0.1 19003
```

---

## Installing

### Standalone binary (any Linux, x86_64 or aarch64)

Download the static binary for your architecture from the [latest release](https://github.com/dirless/trash-panda-db/releases/latest). It has no runtime dependencies — copy it anywhere and run it:

```bash
# x86_64
curl -Lo trashpandadb https://github.com/dirless/trash-panda-db/releases/latest/download/trashpandadb-x86_64
chmod +x trashpandadb
./trashpandadb --raft 0.0.0.0:9001 --client 0.0.0.0:9002 --data-dir ./data
```

### RPM (Fedora, RHEL, AlmaLinux, Rocky)

Download the RPM for your architecture from the [latest release](https://github.com/dirless/trash-panda-db/releases/latest) and install it:

```bash
# x86_64
sudo rpm -i trash-panda-db-0.4.0-1.x86_64.rpm

# aarch64
sudo rpm -i trash-panda-db-0.4.0-1.aarch64.rpm
```

This creates a `trashpandadb` system user, installs the binary to `/usr/bin/trashpandadb`, and drops a systemd unit and config file:

```bash
# Optional: edit ports or set DNS peers
sudo vi /etc/trashpandadb/env

# Start and enable on boot
sudo systemctl enable --now trashpandadb

# Check logs
journalctl -u trashpandadb -f
```

The default config listens on `0.0.0.0:9001` (Raft) and `0.0.0.0:9002` (client). For a replicated cluster, uncomment `DNS_PEERS` in `/etc/trashpandadb/env`.

---

## Building

Requires Crystal ≥ 1.20. With [just](https://github.com/casey/just) installed:

```bash
just build-dev    # fast debug build
just build        # optimised release build
just install      # release build + install to /usr/local/bin (requires sudo)
just build-image  # build the container image (no host Crystal required)
```

Or directly:

```bash
shards install
crystal build src/trashpandadb.cr -o bin/trashpandadb --release
```

---

## Testing

```bash
crystal spec --no-color                             # full suite (533 examples)
crystal spec spec/sql_spec.cr                       # SQL engine only
crystal spec spec/persistence_spec.cr               # storage / WAL
crystal spec spec/replication/raft_node_spec.cr     # Raft state machine
```

The Podman integration test (`spec/replication/podman_spec.cr`) is skipped automatically when `podman` is not in PATH.

### Load testing

See [Testing.md](Testing.md) for full results. Quick summary: 3-node cluster, 20 concurrent writers, 30 seconds — **25,330 writes, 0 failures, 844 writes/s, all nodes consistent**.
