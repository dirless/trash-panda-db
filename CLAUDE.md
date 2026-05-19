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
     wal.cr         — write-ahead log (commit frames, replay on crash recovery)
     pager.cr       — page I/O, page cache, WAL integration, checkpointing
     serialization.cr — JSON serialization for DB persistence across sessions
   connection.cr    — DB::Connection impl, replay_from_pager on open, flush_to_pager on close
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
- **JSON serialization** — database state is serialized as JSON into pages. Simple but not space-efficient.
- **No prepared statement separation** — `build_prepared_statement` and `build_unprepared_statement` both return the same `Statement` class (parsed at exec time).
- **All connections share one `SQL::Database`** — the `ConnectionBuilder` creates a single `SQL::Database` and passes it to every connection in the pool (see `driver.cr:8-9`).
- **WAL checkpoint threshold** — auto-checkpoints when committed pages >= 64 (`pager.cr:162`).
- **Mutex serialization** — all `SQL::Database#execute` calls go through a single `@mutex.synchronize`.

## Status (2026-05-18)

- **398 specs: 0 failures, 0 errors, 5 pending**

## Replication (Raft)

Files in `src/trash_panda_db/replication/`:
- `log_entry.cr` — `LogEntry` struct (term, index, sql — args inlined, no placeholders)
- `raft_log.cr` — append-only JSONL log; `append_entries` handles truncation; persisted to `data_dir/raft_log.jsonl`
- `messages.cr` — `RequestVote`, `RequestVoteReply`, `AppendEntries`, `AppendEntriesReply`; `to_wire` injects `"type"` field; `parse_message` dispatches
- `raft_node.cr` — full Raft state machine; TCP transport (one JSON line per RPC); election timeout 150-600ms; heartbeat 50ms

`RaftNode.new(node_id:, listen_addr:, peers:, sql_db:, data_dir:)` — `data_dir` enables persistence of `raft_state.json` (term, voted_for, commit_index) and `raft_log.jsonl`. On restart, replays committed entries into `sql_db` before `start` is called.

**Key design notes:**
- `become_leader_locked` / `step_down_locked` — called while holding `@mu`; `replicate_to_all` always called outside `@mu` (via `spawn`) to avoid recursive lock
- Single-node fast path: `replicate_to_all` with no peers immediately advances `@commit_index`
- Commit election vote: peer fibers call `become_leader_locked` directly under `@mu`; idempotent guard `return if @role == Role::Leader` prevents double-election
- Quorum uses `//` (integer division): Crystal 1.20 changed `/` on integers to return `Float64`, so `(@peers.size + 1) // 2` is required
- Followers apply entries via `@apply_channel` (buffered 64); leader's `propose` blocks on per-index `Channel` until applied
- Specs: `spec/replication/raft_log_spec.cr`, `raft_node_spec.cr`, `messages_spec.cr`, `podman_spec.cr` — 398 total, 0 failures
