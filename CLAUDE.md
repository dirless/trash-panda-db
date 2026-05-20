# CLAUDE.md

## Project

TrashPandaDB — a pure Crystal embedded database with crystal-db compatibility.
No C bindings, no system library dependencies. Goal: Raft replication eventually.

## Build & Test

```bash
crystal build src/trash_panda_db.cr -o trash_panda_db  # compile
crystal spec --no-color                                  # full suite
crystal spec spec/persistence_spec.cr                    # single spec file
```

## Architecture

```
 src/trash_panda_db/
   sql/
     value.cr       — SQL::Value alias (Nil | Bool | Int64 | Float64 | String | Bytes)
     lexer.cr       — hand-written SQL lexer (TokenKind enum + Lexer class)
     ast.cr         — AST node types (Expr, Stmt, ColDef, etc.)
     parser.cr      — recursive-descent parser (Lexer tokens → AST)
     database.cr    — SQL engine: CREATE/INSERT/SELECT/UPDATE/DELETE/DROP, txns, savepoints
   storage/
     constants.cr   — PAGE_SIZE (4096), magic bytes, header layouts
     wal.cr         — write-ahead log (commit frames, savepoint stack, replay on crash recovery)
     pager.cr       — page I/O, page cache, WAL integration, checkpointing
     page_layout.cr — low-level page read/write helpers (leaf/internal page format)
     btree.cr       — B+ tree (insert with splits, search, scan, delete, update)
     catalog.cr     — persists table schema + btree root page + next_rowid per table
     row_codec.cr   — compact binary row encoding; big-endian Int64 keys for sort order
   connection.cr    — DB::Connection impl, loads catalog on open, commits WAL on close
   statement.cr     — DB::Statement impl, arg coercion (widens small int/float types to Int64/Float64)
   result_set.cr    — DB::ResultSet impl with typed read overloads
   driver.cr        — DB::Driver impl, registers "trashpanda" URI scheme
   trash_panda_db.cr — entry point, requires all modules
```

## URI Format

- File: `trashpanda:/path/to/db.tpdb`
- In-memory: `trashpanda::memory:`

## Key Design Decisions

- **Page-based storage** — 4KB pages, DB header (64 bytes) + pages, WAL in separate `-wal` file.
- **Binary B-tree storage** — each table gets a B+ tree rooted at a catalog-tracked page; rows are encoded with `RowCodec` (compact binary, big-endian Int64 keys for sort order). Replaces the old JSON serialization.
- **Btree is single source of truth** — `Table` holds only `schema` and `next_rowid`; no `rows` array. All reads/writes go through the btree. `SQL::Database` always has a `Storage::Pager` (defaults to `Storage::Pager.new(nil)` for in-memory).
- **Transaction isolation** — `execute()` passes `committed_only = !in_txn && !@tx_stack.empty?` to `exec_select`. Concurrent readers get `BTree.new(pager, root, committed_only: true)` which calls `pager.read_page_committed` (skips dirty WAL pages). Owning connection sees its own dirty writes via the normal btree path.
- **PK point lookups** — `extract_pk_key` detects `WHERE int_pk_col = val` and uses `bt.search(key)` directly in SELECT/UPDATE/DELETE instead of a full scan.
- **Secondary indexes** — `CREATE [UNIQUE] INDEX name ON tbl(col)` backed by a B+ tree. Key = (col_val_bytes ∥ rowid_bigendian). INSERT/UPDATE/DELETE maintain all covering indexes. SELECT detects `WHERE indexed_col = val` (equality) or `WHERE col >/>=/</<= val` (range) and uses the index btree. Index metadata persisted in catalog (`@indexes`, `@index_btrees`, `@col_indexes` in Database). UNIQUE indexes enforce uniqueness at insert/update time.
- **Constraint enforcement** — NOT NULL columns (marked in `ColSchema`) raise `DB::Error` when an INSERT or UPDATE would set them to NULL.
- **VACUUM** — rebuilds all table and index btrees from scratch, returning freed pages to the pager free list.
- **Savepoint stack** — WAL has `push/pop/release_savepoint` that snapshot/restore `@dirty`; `SQL::Database` calls these on create/rollback/release so btree dirty pages are properly unwound.
- **Reentrant mutex** — `@mutex = Mutex.new(:reentrant)` allows SQL `SAVEPOINT` statements executed inside `execute()` to re-enter the mutex without deadlock.
- **No prepared statement separation** — `build_prepared_statement` and `build_unprepared_statement` both return the same `Statement` class (parsed at exec time).
- **All connections share one `SQL::Database`** — the `ConnectionBuilder` creates a single `SQL::Database` and passes it to every connection in the pool (see `driver.cr:8-9`).
- **WAL checkpoint threshold** — auto-checkpoints when committed pages >= 64 (`pager.cr:162`).

## Status (2026-05-20)

- **469 specs: 0 failures, 0 errors, 5 pending** (podman tests fail only when Podman is unavailable)

## Next step

Multi-page catalog (current single-page catalog has a 4 KB limit, limits large schemas). OR: JOIN support, sub-select in FROM, GROUP BY / HAVING, multi-column indexes.

## Replication (Raft)

Files in `src/trash_panda_db/replication/`:
- `log_entry.cr` — `LogEntry` struct; `entry_type` field ("sql" default, "add" for membership); `node_id`/`raft_addr`/`client_addr` for "add" entries; factory methods `sql_entry` and `add_node`
- `raft_log.cr` — append-only JSONL log; `append_entries` handles truncation; `append_add_node` for membership entries; persisted to `data_dir/raft_log.jsonl`
- `messages.cr` — `RequestVote`, `RequestVoteReply`, `AppendEntries`, `AppendEntriesReply`; `to_wire` injects `"type"` field; `parse_message` dispatches
- `raft_node.cr` — full Raft state machine; TCP transport (one JSON line per RPC); election timeout 150-600ms; heartbeat 50ms; single-server membership changes via `propose_add_node`

`RaftNode.new(node_id:, listen_addr:, peers:, client_peers:, sql_db:, data_dir:, joining:)` — `client_peers` is `Hash(String, String)` (node_id → client addr) for write forwarding; `joining: true` suppresses elections until `finish_joining` is called. `data_dir` enables persistence. On restart, replays committed "sql" and "add" entries to reconstruct both DB state and cluster membership.

**Key design notes:**
- `become_leader_locked` / `step_down_locked` — called while holding `@mu`; `replicate_to_all` always called outside `@mu` (via `spawn`) to avoid recursive lock
- Single-node fast path: `replicate_to_all` with no peers immediately advances `@commit_index`
- Commit election vote: peer fibers call `become_leader_locked` directly under `@mu`; idempotent guard `return if @role == Role::Leader` prevents double-election
- Quorum uses `//` (integer division): Crystal 1.20 changed `/` on integers to return `Float64`, so `(@peers.size + 1) // 2` is required
- Followers apply entries via `@apply_channel` (buffered 64); leader's `propose` blocks on per-index `Channel` until applied
- Specs: `spec/replication/raft_log_spec.cr`, `raft_node_spec.cr`, `messages_spec.cr`, `podman_spec.cr` — 398 total, 0 failures
