# Plan

## Status

| Phase | Items | State |
|-------|-------|-------|
| Bug fixes (Items 1–10) | 10 | ✅ All done — committed `bdac3af` (2026-05-21) |
| Housekeeping (Items 11–14) | 4 | ✅ All done — committed `e0d24dc` (2026-05-21) |
| Remaining work (Items 15–16) | 2 | 🔲 Open |

---

# Bug-Fix Plan (completed)

Findings from a full static review of the codebase (May 2026).
All 10 items were fixed in commit `bdac3af`. As a side-effect of the correctness fixes,
3-node benchmark throughput improved from 844 → 4,289 writes/s (5.1×).

Items are kept below for reference.

---

## Item 1 — Socket leak in `send_rpc` [HIGH]

**File:** `src/trash_panda_db/replication/raft_node.cr` ~line 993

**Root cause:**
`sock = TCPSocket.new(...)` is assigned before the `rescue` block. If `sock.puts` or
`sock.gets` raises (e.g. `IO::TimeoutError` from the 0.5 s read timeout), execution
jumps to `rescue nil` and `sock.close` is never reached. One FD is leaked per failed
RPC. At a 50 ms heartbeat interval with N peers, a single unreachable peer drains the
process FD limit in minutes.

**Fix:**
Wrap the socket work in a `File.open`-style block or add an `ensure sock.close` so the
socket is closed regardless of outcome:

```crystal
private def send_rpc(addr : String, wire : String) : String?
  host, port = split_addr(addr)
  sock = TCPSocket.new(host, port.to_i, connect_timeout: 0.2.seconds)
  sock.read_timeout  = 0.5.seconds
  sock.write_timeout = 0.5.seconds
  sock.puts(wire)
  sock.gets
rescue
  nil
ensure
  sock.try &.close
end
```

---

## Item 2 — Deadlock in `propose` when node steps down mid-call [HIGH]

**File:** `src/trash_panda_db/replication/raft_node.cr` ~line 182

**Root cause:**
`@role == Role::Leader` is checked **outside** `@mu`. A concurrent `handle_append_entries`
fiber can call `step_down_locked` (under `@mu`) between the check and the
`@mu.synchronize` block that calls `@log.append`. The entry is written to the log and
`reply_ch` is stored in `@pending`, but `replicate_to_all` returns immediately (not
leader) and no fiber will ever commit the entry. `reply_ch.receive` blocks forever,
hanging the client connection.

The same race exists in `propose_add_node` (~line 201).

**Fix (two parts):**

1. Move the leadership check inside `@mu`:

```crystal
def propose(sql : String, args : Array(SQL::Value)) : SQL::ExecuteResult
  inlined = inline_args(sql, args)
  reply_ch = Channel(SQL::ExecuteResult | Exception).new(1)
  @mu.synchronize do
    raise DB::Error.new("not the leader (leader=#{@leader_id})") unless @role == Role::Leader
    entry = @log.append(@current_term, inlined)
    @pending_mu.synchronize { @pending[entry.index] = reply_ch }
  end
  replicate_to_all
  result = reply_ch.receive
  raise result if result.is_a?(Exception)
  result.as(SQL::ExecuteResult)
end
```

2. In `stop`, drain `@pending` and `@pending_config` so in-flight callers get an error
   instead of hanging forever:

```crystal
def stop : Nil
  @stop_channel.close rescue nil
  @tcp_server.try &.close rescue nil
  @log.close
  err = DB::Error.new("node stopped")
  @pending_mu.synchronize do
    @pending.each_value { |ch| ch.send(err) rescue nil }
    @pending.clear
  end
  @pending_config_mu.synchronize do
    @pending_config.each_value { |ch| ch.send(err) rescue nil }
    @pending_config.clear
  end
end
```

---

## Item 3 — TOCTOU in `send_install_snapshot` (wrong-indexed snapshot sent to follower) [HIGH]

**File:** `src/trash_panda_db/replication/raft_node.cr` ~line 851

**Root cause:**
`@snapshot_last_index` is read under `@mu` (line 851), but `File.open(snap_path, "rb")`
is called **outside** `@mu` (line 857). Crystal fibers yield at IO boundaries; between
the two points the apply loop can run `take_snapshot`, atomically rename a newer snapshot
file into `snap_path`, and update `@snapshot_last_index`. `send_install_snapshot` then
reads the index-N+k file but broadcasts `last_included_index = N`, causing the follower
to record the wrong applied index against the wrong DB state — silent data corruption.

**Fix:**
Copy the snapshot file to a per-session temp path while holding `@mu` (or immediately
after reading the index) so the file content and the index are captured atomically.
A simpler approach: open and read the file size under `@mu`, then copy it to a local
temp path before releasing the lock.

```crystal
private def send_install_snapshot(peer_id : String)
  addr = @peers[peer_id]? || return
  snap_path = @snapshot_path || return

  # Capture metadata AND make a stable copy of the file under @mu so
  # a concurrent take_snapshot cannot replace it mid-transfer.
  term, last_inc_idx, last_inc_term, local_copy = @mu.synchronize do
    idx  = @snapshot_last_index
    return if idx == 0
    trm  = @current_term
    itrm = @log.term_at(idx)
    tmp  = snap_path + ".send_#{peer_id}"
    begin
      File.copy(snap_path, tmp)
    rescue
      return
    end
    {trm, idx, itrm, tmp}
  end

  buf = Bytes.new(SNAPSHOT_CHUNK_SIZE)
  File.open(local_copy, "rb") do |f|
    # ... existing chunked-send loop using local_copy ...
  end
ensure
  File.delete(local_copy) rescue nil
end
```

---

## Item 4 — `@pending_config_change` permanently stuck after step-down and re-election [HIGH]

**File:** `src/trash_panda_db/replication/raft_node.cr` ~line 760

**Root cause:**
In `apply_add_node`, `@pending_config_change = false` is only executed when
`@role == Role::Leader`. If the node that proposed the add_node entry steps down before
it commits, the entry eventually commits on this node as a follower — but the flag is
not cleared. If the node re-wins leadership, every subsequent `propose_add_node` call
hits the guard `raise … "membership change in progress"` and never recovers without a
restart.

**Fix:**
Clear the flag unconditionally in `apply_add_node`:

```crystal
# was: @pending_config_change = false if @role == Role::Leader
@pending_config_change = false
```

The flag is only ever set on the leader, and clearing it on a follower is a no-op with
no negative side effect. The comment "idempotent on followers where it was never set" is
correct — the change makes it literally idempotent.

---

## Item 5 — `save_persistent_state` silently swallows all errors [HIGH]

**File:** `src/trash_panda_db/replication/raft_node.cr` ~line 973

**Root cause:**
The method ends with a bare `rescue` that catches every exception, including
`File::Error` from a full disk or missing directory. Callers (`advance_commit_index_locked`,
`handle_install_snapshot`, `take_snapshot`) assume the state was written. On restart the
node loads the stale `raft_state.json` and may re-vote in a term it already voted in,
violating the "one vote per term" invariant.

**Fix:**
Log the error and propagate it (or at minimum log it so operators can diagnose):

```crystal
private def save_persistent_state
  path = @state_path || return
  state = PersistentState.new(@current_term, @voted_for, @commit_index, @last_applied)
  write_json_atomic(path, state.to_json)
rescue ex
  STDERR.puts "[#{@node_id}] FATAL: could not persist Raft state: #{ex.class}: #{ex.message}"
  raise ex  # let the caller decide whether to crash or handle
end
```

Callers that currently don't rescue `save_persistent_state` will automatically surface
the failure rather than silently continuing with un-persisted state.

---

## Item 6 — `handle_install_snapshot` holds `@mu` across all File I/O [MEDIUM]

**File:** `src/trash_panda_db/replication/raft_node.cr` ~line 898

**Root cause:**
The entire method body is inside `@mu.synchronize`, including `File.open`, `f.write`,
`f.fsync`, and `File.copy`. Crystal fibers yield at IO boundaries; while the disk write
is in progress every other fiber that calls `@mu.synchronize` (heartbeat, apply loop,
election timeout, `replicate_to`) is blocked. For a large snapshot on a slow disk this
stall can exceed `ELECTION_TIMEOUT_MIN` (150 ms), causing peers to hold a new election.

**Fix:**
Hold `@mu` only for the pure in-memory state updates; release it around all File I/O.
Structure the handler as: validate/update state under lock → write file outside lock →
re-acquire lock to commit final state changes.

```crystal
private def handle_install_snapshot(msg : InstallSnapshot) : InstallSnapshotReply
  # Phase 1: validate and update in-memory transfer state under @mu.
  tmp_path, should_apply = @mu.synchronize do
    # ... validation, step_down_locked if needed, out-of-order chunk check ...
    # return early reply if invalid
    tmp = (@snapshot_path || "/tmp/raft_snapshot_transfer.db").not_nil! + ".transfer"
    # update @xfer_index, @xfer_offset
    {tmp, msg.done}
  end

  # Phase 2: write chunk to disk WITHOUT holding @mu.
  chunk = Base64.decode(msg.data)
  # ... open/write tmp_path ...

  return InstallSnapshotReply.new(@current_term, true) unless should_apply

  # Phase 3: final apply — fsync, replace pager, update log — under @mu.
  @mu.synchronize do
    # ... fsync, replace_pager_from_file, install_snapshot, save_persistent_state ...
    InstallSnapshotReply.new(@current_term, true)
  end
end
```

---

## Item 7 — Unbounded fiber spawning in `replicate_to_all` [MEDIUM]

**File:** `src/trash_panda_db/replication/raft_node.cr` ~line 530

**Root cause:**
`replicate_to_all` spawns `spawn replicate_to(peer_id)` on every call (heartbeat every
50 ms) with no per-peer guard. If a peer is slow or needs a snapshot (transfer can take
seconds), new fibers accumulate faster than they finish. Multiple concurrent
`send_install_snapshot` fibers for the same peer each send `offset=0` on their first
chunk, resetting the follower's `@xfer_index` and preventing the transfer from ever
completing. Fiber and FD counts grow without bound.

**Fix:**
Track an in-flight set per peer and skip spawning if one is already running:

```crystal
@replicating = Set(String).new   # add to initialize
@replicating_mu = Mutex.new

private def replicate_to_all
  return unless @role == Role::Leader
  @peers.each_key do |peer_id|
    @replicating_mu.synchronize do
      next if @replicating.includes?(peer_id)
      @replicating.add(peer_id)
    end
    spawn do
      replicate_to(peer_id)
    ensure
      @replicating_mu.synchronize { @replicating.delete(peer_id) }
    end
  end
  # ... single-node commit path unchanged ...
end
```

---

## Item 8 — `handle_pre_vote_request` reads log state without `@mu` [MEDIUM]

**File:** `src/trash_panda_db/replication/raft_node.cr` ~line 488

**Root cause:**
`handle_pre_vote_request` reads `@current_term`, `@log.last_term`, and
`@log.last_index` without holding `@mu`. A concurrent `handle_append_entries` fiber
holds `@mu` and mutates the log. In Crystal's multi-threaded build these are unsynchronised
reads of fields being written in another OS thread — a data race. Even in single-threaded
builds an inconsistent snapshot (new `last_index`, stale `last_term`) can cause an
incorrect pre-vote grant.

**Fix:**
Wrap the entire method in `@mu.synchronize` (consistent with how `handle_request_vote`
and `handle_append_entries` are implemented):

```crystal
private def handle_pre_vote_request(msg : PreVoteRequest) : PreVoteReply
  @mu.synchronize do
    return PreVoteReply.new(@current_term, false) if msg.term < @current_term
    grant = msg.last_log_term > @log.last_term ||
            (msg.last_log_term == @log.last_term && msg.last_log_index >= @log.last_index)
    PreVoteReply.new(@current_term, grant)
  end
end
```

No state is mutated, so adding the lock does not affect correctness or introduce
deadlock risk.

---

## Item 9 — `stop()` does not drain `@pending` channels [MEDIUM]

**See Item 2 for the full fix.** This is the shutdown-path manifestation of the same
root cause: the apply loop exits when `@stop_channel` closes, but `@pending` and
`@pending_config` are not drained. Any fiber blocked in `propose()` or
`propose_add_node()` at `reply_ch.receive` hangs forever after `stop()` is called.

The fix in Item 2 (drain both maps in `stop`) resolves this.

---

## Item 10 — FD leak in in-memory `Pager#checkpoint` [LOW]

**File:** `src/trash_panda_db/storage/pager.cr` ~line 161

**Root cause:**
In the in-memory branch of `checkpoint`, `File.open("/dev/null", "wb")` is called to
provide a throwaway `File` handle for `WAL#checkpoint`. The returned `File` object is
never explicitly closed. Crystal's GC will eventually finalise it, but under a
high-throughput in-memory workload (e.g. test clusters, bench harnesses) the GC can lag,
accumulating open `/dev/null` FDs until `EMFILE` is hit.

**Fix:**
Use a block form or assign + close:

```crystal
# Option A — block form (auto-closes)
File.open("/dev/null", "wb") do |devnull|
  @wal.checkpoint(devnull, @page_count)
end rescue nil

# Option B — skip the file entirely (in-memory WAL doesn't write to disk anyway)
# Since the in-memory path already copies committed pages to @cache and then calls
# @wal.committed.clear, the File.open("/dev/null") call is redundant. Remove it and
# call @wal.committed.clear directly without going through WAL#checkpoint at all.
@wal.committed.each { |k, v| @cache[k] = v }
@wal.committed.clear
@wal.instance_variable_get(:@dirty).clear  # or expose a reset method
```

Option B is cleaner: the in-memory checkpoint path does not need WAL#checkpoint at all.

---

## Summary table (all done ✅)

| # | Severity | File | ~Line | One-line description |
|---|----------|------|-------|----------------------|
| 1 | HIGH | `raft_node.cr` | 993 | Socket not closed in `send_rpc` rescue path |
| 2 | HIGH | `raft_node.cr` | 182 | Leadership check outside `@mu` → `propose` deadlock |
| 3 | HIGH | `raft_node.cr` | 851 | TOCTOU in `send_install_snapshot` → wrong snapshot index sent |
| 4 | HIGH | `raft_node.cr` | 760 | `@pending_config_change` not cleared on follower → add_node blocked after re-election |
| 5 | HIGH | `raft_node.cr` | 977 | `save_persistent_state` bare rescue → silent state loss, double-vote risk |
| 6 | MEDIUM | `raft_node.cr` | 898 | `handle_install_snapshot` holds `@mu` across File I/O → spurious elections |
| 7 | MEDIUM | `raft_node.cr` | 530 | `replicate_to_all` unbounded fiber spawning → snapshot transfer livelock |
| 8 | MEDIUM | `raft_node.cr` | 488 | `handle_pre_vote_request` reads log without `@mu` → data race |
| 9 | MEDIUM | `raft_node.cr` | 174 | `stop()` doesn't drain `@pending` → fibers hang on shutdown |
| 10 | LOW | `pager.cr` | 161 | `File.open("/dev/null")` not closed in in-memory checkpoint |

---

# Remaining Work

## Item 11 — Collapse triple `@mu` reads in `start_election` [LOW]

**File:** `src/trash_panda_db/replication/raft_node.cr` ~line 375

**Root cause:**
`@current_term`, `@log.last_index`, and `@log.last_term` are read in three separate
`@mu.synchronize` blocks. A heartbeat arriving between any two reads can cause the
`RequestVote` to carry mismatched fields (e.g. `last_log_index` from before a new entry
was appended, `last_log_term` from after). Peers use these fields to decide whether the
candidate's log is up-to-date; a stale pair can cause an incorrect vote grant or denial.

**Fix:**
Read all three fields in a single lock acquisition:

```crystal
term, last_idx, last_term = @mu.synchronize do
  {@current_term, @log.last_index, @log.last_term}
end
```

Replace the three separate `@mu.synchronize` blocks on lines ~375–377 with the above.

---

## Item 12 — `query` checks leadership outside `@mu` [LOW]

**File:** `src/trash_panda_db/replication/raft_node.cr` ~line 237

**Root cause:**
`query` reads `@role` without holding `@mu`. A concurrent `step_down_locked` can demote
the node between the check and the `@sql_db.execute` call. The node then serves a
linearisable read from state that is no longer guaranteed to be current, breaking the
read-your-writes guarantee for clients that just wrote through this leader.

**Fix:**
Move the guard inside `@mu` (consistent with the fix applied to `propose` in Item 2):

```crystal
def query(sql : String, args : Array(SQL::Value) = [] of SQL::Value) : SQL::QueryResult
  @mu.synchronize do
    raise DB::Error.new("not the leader (leader=#{@leader_id})") unless @role == Role::Leader
  end
  result = @sql_db.execute(sql, args)
  result.as(SQL::QueryResult)
end
```

Note: `@sql_db.execute` already holds its own mutex internally, so it does not need
to run under `@mu`.

---

## Item 13 — Re-run benchmarks for 6, 9, 12, 15-node clusters [HOUSEKEEPING]

**File:** `Testing.md`

**Root cause:**
All multi-node benchmark results in Testing.md were captured before the bug fixes. The
summary table flags them as "pre-fix". The 3-node post-fix run showed a 5.1× throughput
improvement; the other cluster sizes should be re-benchmarked so all numbers are
comparable and the summary table is accurate.

**Fix:**
Run the hammer for each cluster size and update Testing.md:

```bash
# Rebuild the image first (once)
crystal build src/trashpandadb.cr -o bin/trashpandadb
podman build -t trash-panda-raft -f Containerfile .

# Then benchmark each size
bin/hammer --nodes 6  --writers 20 --duration 30
bin/hammer --nodes 9  --writers 20 --duration 30
bin/hammer --nodes 12 --writers 20 --duration 30
bin/hammer --nodes 15 --writers 20 --duration 30
```

Update each result section and the summary table in Testing.md, then update the
README's Testing section with the new 3-node throughput figure.

---

## Item 14 — Fix stale example count in README [HOUSEKEEPING]

**File:** `README.md` ~line 334

**Root cause:**
The Testing section says "full suite (533 examples)" but `crystal spec` now reports
536 examples.

**Fix:**
Update the line:

```
crystal spec --no-color                             # full suite (536 examples)
```

---

## Item 15 — `DISTINCT` in `SELECT` [FEATURE]

**File:** `src/trash_panda_db/sql/` (parser, AST, database)

**Root cause / scope:**
`SELECT DISTINCT` is not yet parsed or evaluated. It is a commonly expected SQL feature.

**Fix (sketch):**
1. Add a `distinct : Bool` field to `AST::Select`.
2. In `Parser`, set it when `DISTINCT` follows `SELECT`.
3. In `Database#exec_select`, after projecting rows, filter out duplicates:

```crystal
if stmt.distinct
  seen = Set(String).new
  result_rows.select! { |row| seen.add(row.map(&.inspect).join("\x00")) }
end
```

---

## Item 16 — `query` linearisability: read-index protocol [MEDIUM]

**File:** `src/trash_panda_db/replication/raft_node.cr`

**Root cause:**
Even after Item 12's guard is in place, a leader can serve a stale read if it has been
partitioned away from the cluster and does not yet know it has been replaced. The Raft
paper (§8) prescribes a **read-index** protocol: before serving a read the leader
exchanges a round of heartbeats to confirm it still holds a majority, then waits for
`last_applied ≥ read_index` before executing the query.

**Fix (sketch):**
1. Before executing a query, record `read_index = @commit_index` under `@mu`.
2. Send a no-op heartbeat to all peers and wait for a majority acknowledgement.
3. Wait until `@last_applied >= read_index`.
4. Execute the query.

This is a significant addition — it requires a new channel/callback path for heartbeat
confirmations and may impact read latency. Implement only if strict linearisable reads
are required; for many workloads the current "leader-only" approach is sufficient.

---

## Remaining work summary

| # | Severity | Description | State |
|---|----------|-------------|-------|
| 11 | LOW | Collapse triple `@mu` reads in `start_election` | ✅ Done |
| 12 | LOW | `query` leadership check outside `@mu` | ✅ Done |
| 13 | — | Re-run 6/9/12/15-node benchmarks (Testing.md housekeeping) | ✅ Done |
| 14 | — | Fix stale example count in README (533 → 536) | ✅ Done |
| 15 | FEATURE | `SELECT DISTINCT` support | 🔲 Open |
| 16 | MEDIUM | Read-index protocol for fully linearisable `query` | 🔲 Open |
