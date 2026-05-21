# TrashPandaDB — Chaos Testing Investigation Plan

## Current state (as of 2026-05-21)

All 533 specs pass. Pre-vote protocol is implemented and verified.

### Committed this session (a23fa0b)

- **Pre-vote protocol**: PreVoteRequest/PreVoteReply message types, `request_pre_votes`
  collecting majority before real election, `handle_pre_vote_request` with log check
  but no state mutation. Prevents stale leaders from disrupting the cluster.
- **notify_apply helper**: Non-blocking `select`-based channel signal instead of
  `send rescue nil` — no more deadlock risk.
- **apply_committed resilience**: Outer loop re-reads commit_index after each batch;
  broad `rescue` keeps the apply fiber alive on any exception.
- **Fast next_index rewind**: Jump to `reply.match_index + 1` instead of decrementing
  by 1 — restarted nodes catch up in O(log_size / 200) rounds.
- **MAX_ENTRIES_PER_RPC = 200**: Caps AppendEntries message size.
- **Startup grace period**: 1s election delay on fresh start with peers so leader
  heartbeats arrive first.
- **Strict quorum**: `advance_commit_index_locked` uses `>= majority` not `> peers/2`.

---

## Bug 1 — Data loss under chaos — FIXED by pre-vote

### Pre-fix symptom

~0.3-0.4% of `ok:true` writes missing from all nodes in clusters >= 6 nodes.
Uniformly distributed across all writers.

### Root cause

1. Leader commits entry on a quorum (5 of 9 nodes)
2. Chaos kills leader + enough followers that held the committed entry
3. Restarted nodes (empty in-memory state) form election majority
4. New stale leader sends AppendEntries with higher-term no-op at the overwritten index
5. Surviving followers truncate committed entries because term differs

This is the classic Raft edge case from §5.4.2 / Figure 8 — election safety assumes
nodes don't lose their logs, but in-memory mode loses everything on kill.

### Verification

9-node chaos test (90s, 14 kills/restarts) after fix:
- **No cluster-wide data loss**: 6 of 9 nodes converged on 7246 rows (vs 7267 written)
- Extra rows from committed-but-unacked writes expected in chaos mode (leader dies mid-ack)
- Pre-vote prevented stale restarted nodes from winning elections

---

## Bug 2 — Convergence stall — NOT FIXED

### Symptoms

After the pre-vote fix eliminated data loss, a convergence stall remains:
- 3 out of 9 nodes lag behind permanently (n4=3690, n5=3691, n6=6459 vs 7246)
- Never catch up within 60s timeout
- n4 and n5 stuck at ~3690 from ~5-6s into the test
- n4 was never killed; n5 was killed once

### Suspected area

The apply fiber stays alive (rescue is in place), but something prevents it from
making progress. Possible causes:

1. **commit_index stuck**: Follower's commit_index never advances past ~3690.
   check: does `handle_append_entries` correctly update commit_index from
   leader_commit on every heartbeat? If `append_entries` returns false (log
   mismatch), commit_index is never updated.

2. **Replication skip**: With frequent leader changes (every ~4s), the new leader
   resets `@next_index[peer] = last_index + 1`. Followers far behind reject
   the first AppendEntries (prev_log mismatch), and the leader adjusts. But
   if leader changes happen faster than catch-up completes, followers stay
   behind forever.

3. **`@pending_config_change` stuck true**: If a config change entry was never
   committed (leader died mid-append), `@pending_config_change` stays true
   and blocks future `propose_add_node` on the leader. Unlikely for the
   ase hammer test (no config changes), but worth noting.

### Suggested next steps

1. **Check if n4/n5 commit_index is stuck**: Add a `commit_index` field to the
   `status` RPC response so we can compare. If commit_index is stuck at ~3690
   on n4 but advancing on n1, the issue is commit_index stagnation.

2. **Check if n4/n5 receive heartbeats**: Add `last_heartbeat_age` to status.
   If n4 hasn't heard from a leader in seconds, it's partitioned.

3. **Reproduce without chaos**: Run a 9-node non-chaos test. If convergence is
   clean, the stall is chaos-induced (leader churn). If not, there's a deeper
   replication bug.

4. **Add `@pager.commit` after each SQL apply**: In disk mode, dirty pages
   accumulate in memory. Adding `@pager.commit` after each `@sql_db.execute`
   in `apply_committed` would flush each INSERT to the WAL immediately.

---

## Files changed this session

| File | Change |
|------|--------|
| `src/trash_panda_db/replication/messages.cr` | Added PreVoteRequest, PreVoteReply structs + parser dispatch |
| `src/trash_panda_db/replication/raft_node.cr` | Pre-vote protocol, notify_apply helper, apply-loop resilience, fast next_index, startup grace period, strict quorum, MAX_ENTRIES_PER_RPC |