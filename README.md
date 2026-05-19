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
  - [Client API](#client-api)
- [Building](#building)
- [Testing](#testing)
- [Architecture](#architecture)

---

## Embedded Use

Add to `shard.yml`:

```yaml
dependencies:
  trash-panda-db:
    github: your-org/trash-panda-db
    version: "~> 0.1"
```

```crystal
require "trash_panda_db"

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
| `JOIN` (INNER, LEFT, CROSS) | Yes |
| `GROUP BY`, `HAVING` | Yes |
| Aggregate functions (`COUNT`, `SUM`, `AVG`, `MIN`, `MAX`) | Yes |
| Subqueries | Yes |
| `BEGIN` / `COMMIT` / `ROLLBACK` | Yes |
| `SAVEPOINT` / `RELEASE` / `ROLLBACK TO SAVEPOINT` | Yes |
| `PRIMARY KEY`, `NOT NULL`, `UNIQUE`, `DEFAULT` | Yes |
| `CAST`, `LIKE`, `IN`, `IS NULL`, `BETWEEN` | Yes |
| `REGEXP` | Yes |
| Parameter binding (`?`) | Yes |

Value types: `NULL`, `INTEGER` (Int64), `REAL` (Float64), `TEXT`, `BLOB`.

---

## Storage

- **Page-based**: 4 KB pages. Database header occupies page 0.
- **WAL**: Writes go to a `-wal` file first. Checkpointed to the main file when ≥ 64 pages accumulate.
- **JSON serialization**: Database state is serialised as JSON into pages. Simple; not space-optimised.
- **Crash recovery**: WAL is replayed on open. A clean checkpoint removes the WAL file.

---

## Raft Replication

TrashPandaDB ships a standalone server binary that runs a Raft node, exposes a JSON-over-TCP client API, and transparently forwards writes from followers to the leader.

### Standalone Server

Build the binary on the host (requires Crystal ≥ 1.20):

```bash
crystal build src/raft_node_server.cr -o bin/raft_node_server
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

**Cluster-size guard**: by default the server refuses to start unless the A record resolves to exactly **3** IPs. Change the expected size with `--dns-cluster-size N`:

```
ERROR: --dns-cluster-size is 3 but 'db-cluster.example.com' resolved to 2 addresses (10.0.0.1, 10.0.0.2).
Update the DNS record to list exactly 3 IPs, or adjust --dns-cluster-size.
```

This means scaling the cluster is as simple as updating the DNS record (and ensuring all nodes restart or are added with the new `--dns-cluster-size`).

**DNS options:**

| Flag | Default | Description |
|---|---|---|
| `--dns-peers HOSTNAME` | — | DNS A-record hostname for peer discovery |
| `--dns-raft-port PORT` | `9001` | Raft RPC port for discovered peers |
| `--dns-client-port PORT` | `9002` | Client API port for discovered peers |
| `--dns-cluster-size N` | `3` | Expected total node count; startup fails if the record has a different number of IPs |

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

### Client API

Each node listens on a TCP client port (default 9002). Send one JSON line per connection; the response is one JSON line.

**status**
```json
{"action":"status"}
// → {"ok":true,"role":"Leader","node_id":"10.91.0.12","leader_id":"10.91.0.12","term":1}
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

## Building

```bash
# Install dependencies
shards install

# Compile the library (check it type-checks)
crystal build src/trash_panda_db.cr -o trash_panda_db

# Compile the standalone Raft server
crystal build src/raft_node_server.cr -o bin/raft_node_server
```

Requires Crystal ≥ 1.20.

---

## Testing

```bash
crystal spec --no-color          # full suite (398 examples, ~16s)
crystal spec spec/sql_spec.cr    # SQL engine only
crystal spec spec/persistence_spec.cr
crystal spec spec/replication/raft_node_spec.cr
```

The Podman integration test (`spec/replication/podman_spec.cr`) is skipped automatically when `podman` is not in PATH.

---

## Architecture

```
src/trash_panda_db/
  sql/
    value.cr          — SQL::Value alias (Nil | Bool | Int64 | Float64 | String | Bytes)
    lexer.cr          — hand-written SQL lexer
    ast.cr            — AST node types (Expr, Stmt, ColDef, …)
    parser.cr         — recursive-descent parser
    database.cr       — SQL engine: CREATE/INSERT/SELECT/UPDATE/DELETE/DROP, transactions, savepoints
  storage/
    constants.cr      — PAGE_SIZE (4096), magic bytes, header layouts
    wal.cr            — write-ahead log: commit frames, crash replay
    pager.cr          — page I/O, page cache, WAL integration, checkpoint at 64 pages
    serialization.cr  — JSON serialization of DB state into pages
  replication/
    log_entry.cr      — LogEntry struct (term, index, sql)
    raft_log.cr       — append-only JSONL log with truncation on conflict
    messages.cr       — RequestVote, AppendEntries and their replies; wire encoding
    raft_node.cr      — full Raft state machine; TCP transport; election/heartbeat fibers
  connection.cr       — DB::Connection impl
  statement.cr        — DB::Statement impl
  result_set.cr       — DB::ResultSet impl
  driver.cr           — DB::Driver impl, registers "trashpanda" URI scheme
  trash_panda_db.cr   — entry point

src/raft_node_server.cr — standalone server: JSON client API, DNS discovery, follower forwarding
Containerfile           — minimal Debian image for the server binary
```

**Key design decisions:**

- All connections share one `SQL::Database` instance. Writes are serialised through a mutex.
- WAL frames are replayed on open; the database is rebuilt from JSON on each restart (no binary page format yet).
- Raft entries inline SQL argument values (no `?` placeholders in the log) so replay needs no parameter context.
- Followers proxy `propose` requests to the leader — clients can write to any node.
- `advance_commit_index_locked` implements Raft §5.4.2: only a current-term entry anchors the commit point; older entries are committed implicitly (Leader Completeness Property). A no-op entry is appended on every leader election to flush any pending old-term entries immediately.
- Crystal 1.20 changed `/` on integers to return `Float64`; all quorum calculations use `//` (integer floor division).
