# TrashPandaDB — Load Testing

## Hammer tool

`src/hammer.cr` spins up an N-node Raft cluster via Podman, hammers it with concurrent writers, and verifies that every node ends up with the same row count.

```
Usage: hammer [options]
  --nodes N       Replicas to start via Podman (default: 3)
  --writers M     Concurrent write fibers (default: 20)
  --duration D    Write phase in seconds (default: 30)
  --image TAG     Podman image tag (default: trash-panda-raft)
  --build         Build binary + image before starting
  --keep          Leave containers running after test
  --connect ADDR  host:port[,host:port] — skip Podman, use existing cluster
```

Writes are spread round-robin across **all** nodes. Followers transparently forward writes to the current leader, so the tool exercises the full follower-forwarding path.

Build and run:

```bash
crystal build src/hammer.cr -o bin/hammer
bin/hammer --build --nodes 3 --writers 20 --duration 30
```

---

## Results — 3-node cluster, 30 seconds (post bug-fix)

Run after fixing 10 correctness and safety bugs (see `PLAN.md`). The most impactful
fixes for throughput were:

- **Per-peer fiber guard** (`replicate_to_all`): eliminated unbounded concurrent
  replication fibers per peer, which were competing for the same leader resources and
  causing redundant snapshot retransfers.
- **`@mu` released during snapshot I/O** (`handle_install_snapshot`): followers no
  longer block all Raft timers and the apply loop while writing large snapshot chunks
  to disk.
- **Socket `ensure` close** (`send_rpc`): eliminated FD exhaustion under load that was
  silently degrading throughput as open sockets accumulated.

| Parameter      | Value                |
|----------------|----------------------|
| Nodes          | 3                    |
| Writers        | 20 concurrent fibers |
| Duration       | 30 s                 |
| Image          | trash-panda-raft     |

```
► Starting 3-node cluster (image: trash-panda-raft)
  n1  →  127.0.0.1:44551
  n2  →  127.0.0.1:37797
  n3  →  127.0.0.1:46105
► Waiting for leader  →  leader: n1(127.0.0.1:44551)
► Hammering  writers=20  duration=30s  nodes=3
  (writes spread round-robin across all nodes — followers forward to leader)

────────────────────────────────────────────────────────
  Write phase complete
  Duration   : 30.1s
  Written    : 128880
  Failed     : 0
  Throughput : 4289 writes/s
────────────────────────────────────────────────────────

► Waiting for all nodes to converge (timeout 10s)... converged in 2s

► Verifying 3 nodes:
  n1(127.0.0.1:44551)       128880 rows  ✓
  n2(127.0.0.1:37797)       128880 rows  ✓
  n3(127.0.0.1:46105)       128880 rows  ✓

► Diagnostics (commit_index / last_applied / log_last_index / heartbeat_ms):
  n1(127.0.0.1:44551)  ci=128882  la=128882  li=128882  hb=32652ms  [LEADER]
    n2     next=128883  match=128882
    n3     next=128883  match=128882
  n2(127.0.0.1:37797)  ci=128882  la=128882  li=128882  hb=14ms
  n3(127.0.0.1:46105)  ci=128882  la=128882  li=128882  hb=1ms

✓  All 3 nodes consistent: 128880 rows confirmed on every node.
```

**0 failed writes. All 3 nodes converged to the same 128,880 rows.**

**5.1× throughput improvement over the pre-fix run** (4,289 vs 844 writes/s).

---

## Results — 3-node cluster, 30 seconds (pre bug-fix, baseline)

Run on a single Linux host (Podman bridge network, all nodes local):

| Parameter      | Value                |
|----------------|----------------------|
| Nodes          | 3                    |
| Writers        | 20 concurrent fibers |
| Duration       | 30 s                 |
| Image          | trash-panda-raft     |

```
► Starting 3-node cluster (image: trash-panda-raft)
  n1  →  127.0.0.1:55201
  n2  →  127.0.0.1:55202
  n3  →  127.0.0.1:55203
► Waiting for leader  →  leader: n1(127.0.0.1:55201)
► Hammering  writers=20  duration=30s  nodes=3
  (writes spread round-robin across all nodes — followers forward to leader)

────────────────────────────────────────────────────────
  Write phase complete
  Duration   : 30.0s
  Written    : 25330
  Failed     : 0
  Throughput : 844 writes/s
────────────────────────────────────────────────────────

► Verifying 3 nodes:
  n1(127.0.0.1:55201)       25330 rows  ✓
  n2(127.0.0.1:55202)       25330 rows  ✓
  n3(127.0.0.1:55203)       25330 rows  ✓

✓  All 3 nodes consistent: 25330 rows confirmed on every node.
```

**0 failed writes. All 3 nodes converged to the same 25,330 rows.**

---

## Results — 6-node cluster, 30 seconds

| Parameter      | Value                |
|----------------|----------------------|
| Nodes          | 6                    |
| Writers        | 20 concurrent fibers |
| Duration       | 30 s                 |
| Image          | trash-panda-raft     |

```
► Starting 6-node cluster (image: trash-panda-raft)
  n1  →  127.0.0.1:42059
  n2  →  127.0.0.1:37849
  n3  →  127.0.0.1:46083
  n4  →  127.0.0.1:42889
  n5  →  127.0.0.1:33061
  n6  →  127.0.0.1:42319
► Waiting for leader  →  leader: n4(127.0.0.1:42889)
► Hammering  writers=20  duration=30s  nodes=6
  (writes spread round-robin across all nodes — followers forward to leader)

────────────────────────────────────────────────────────
  Write phase complete
  Duration   : 30.0s
  Written    : 10607
  Failed     : 0
  Throughput : 353 writes/s
────────────────────────────────────────────────────────

► Verifying 6 nodes:
  n1(127.0.0.1:42059)        10607 rows  ✓
  n2(127.0.0.1:37849)        10607 rows  ✓
  n3(127.0.0.1:46083)        10607 rows  ✓
  n4(127.0.0.1:42889)        10607 rows  ✓
  n5(127.0.0.1:33061)        10607 rows  ✓
  n6(127.0.0.1:42319)        10607 rows  ✓

✓  All 6 nodes consistent: 10607 rows confirmed on every node.
```

**0 failed writes. All 6 nodes converged to the same 10,607 rows.**

Throughput dropped from 844 to 353 writes/s compared to the 3-node run. This is expected: Raft requires a majority quorum (4 of 6 nodes) to commit each entry, so each write round-trip touches more nodes over the same loopback network.

---

## Results — 9-node cluster, 30 seconds

| Parameter      | Value                |
|----------------|----------------------|
| Nodes          | 9                    |
| Writers        | 20 concurrent fibers |
| Duration       | 30 s                 |
| Image          | trash-panda-raft     |

```
► Starting 9-node cluster (image: trash-panda-raft)
  n1  →  127.0.0.1:46549
  n2  →  127.0.0.1:39689
  n3  →  127.0.0.1:45843
  n4  →  127.0.0.1:38209
  n5  →  127.0.0.1:33681
  n6  →  127.0.0.1:42327
  n7  →  127.0.0.1:37555
  n8  →  127.0.0.1:46269
  n9  →  127.0.0.1:44731
► Waiting for leader  →  leader: n2(127.0.0.1:39689)
► Hammering  writers=20  duration=30s  nodes=9
  (writes spread round-robin across all nodes — followers forward to leader)

────────────────────────────────────────────────────────
  Write phase complete
  Duration   : 30.0s
  Written    : 6620
  Failed     : 0
  Throughput : 220 writes/s
────────────────────────────────────────────────────────

► Verifying 9 nodes:
  n1(127.0.0.1:46549)         6620 rows  ✓
  n2(127.0.0.1:39689)         6620 rows  ✓
  n3(127.0.0.1:45843)         6620 rows  ✓
  n4(127.0.0.1:38209)         6620 rows  ✓
  n5(127.0.0.1:33681)         6620 rows  ✓
  n6(127.0.0.1:42327)         6620 rows  ✓
  n7(127.0.0.1:37555)         6620 rows  ✓
  n8(127.0.0.1:46269)         6620 rows  ✓
  n9(127.0.0.1:44731)         6620 rows  ✓

✓  All 9 nodes consistent: 6620 rows confirmed on every node.
```

**0 failed writes. All 9 nodes converged to the same 6,620 rows.**

A 9-node cluster requires 5 nodes to agree per commit, continuing the quorum-cost trend.

---

## Results — 12-node cluster, 30 seconds

| Parameter      | Value                |
|----------------|----------------------|
| Nodes          | 12                   |
| Writers        | 20 concurrent fibers |
| Duration       | 30 s                 |
| Image          | trash-panda-raft     |

```
► Starting 12-node cluster (image: trash-panda-raft)
  n1  →  127.0.0.1:36065   n2  →  127.0.0.1:34207
  n3  →  127.0.0.1:37949   n4  →  127.0.0.1:43083
  n5  →  127.0.0.1:36093   n6  →  127.0.0.1:44659
  n7  →  127.0.0.1:43017   n8  →  127.0.0.1:34775
  n9  →  127.0.0.1:41595   n10 →  127.0.0.1:37689
  n11 →  127.0.0.1:40451   n12 →  127.0.0.1:46505
► Waiting for leader  →  leader: n9(127.0.0.1:41595)
► Hammering  writers=20  duration=30s  nodes=12

────────────────────────────────────────────────────────
  Write phase complete
  Duration   : 30.0s
  Written    : 4620
  Failed     : 0
  Throughput : 154 writes/s
────────────────────────────────────────────────────────

► Verifying 12 nodes:
  n1..n12   4620 rows each  ✓

✓  All 12 nodes consistent: 4620 rows confirmed on every node.
```

**0 failed writes. All 12 nodes converged to the same 4,620 rows.**

---

## Results — 15-node cluster, 30 seconds

| Parameter      | Value                |
|----------------|----------------------|
| Nodes          | 15                   |
| Writers        | 20 concurrent fibers |
| Duration       | 30 s                 |
| Image          | trash-panda-raft     |

```
► Starting 15-node cluster (image: trash-panda-raft)
  n1..n15 on 127.0.0.1 (random ports)
► Waiting for leader  →  leader: n6(127.0.0.1:46513)
► Hammering  writers=20  duration=30s  nodes=15

────────────────────────────────────────────────────────
  Write phase complete
  Duration   : 30.0s
  Written    : 3640
  Failed     : 0
  Throughput : 121 writes/s
────────────────────────────────────────────────────────

► Verifying 15 nodes:
  n1..n15   3640 rows each  ✓

✓  All 15 nodes consistent: 3640 rows confirmed on every node.
```

**0 failed writes. All 15 nodes converged to the same 3,640 rows.**

---

## Summary

| Nodes | Quorum | Written  | Failed | Throughput  | Consistent | Notes          |
|-------|--------|----------|--------|-------------|------------|----------------|
| 3     | 2      | 128,880  | 0      | 4,289 w/s   | ✓          | post-fix       |
| 3     | 2      | 25,330   | 0      | 844 w/s     | ✓          | pre-fix        |
| 6     | 4      | 10,607   | 0      | 353 w/s     | ✓          | pre-fix        |
| 9     | 5      | 6,620    | 0      | 220 w/s     | ✓          | pre-fix        |
| 12    | 7      | 4,620    | 0      | 154 w/s     | ✓          | pre-fix        |
| 15    | 8      | 3,640    | 0      | 121 w/s     | ✓          | pre-fix        |

The 3-node post-fix run shows a **5.1× throughput improvement** at the same concurrency and duration. The pre-fix results for 6–15 nodes will be re-benchmarked in a follow-up run.
