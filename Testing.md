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

## Results — 3-node cluster, 30 seconds

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
  n1  →  127.0.0.1:42491
  n2  →  127.0.0.1:36143
  n3  →  127.0.0.1:43541
  n4  →  127.0.0.1:43957
  n5  →  127.0.0.1:41681
  n6  →  127.0.0.1:44099
► Waiting for leader  →  leader: n1(127.0.0.1:42491)
► Hammering  writers=20  duration=30s  nodes=6
  (writes spread round-robin across all nodes — followers forward to leader)

────────────────────────────────────────────────────────
  Write phase complete
  Duration   : 30.0s
  Written    : 88706
  Failed     : 0
  Throughput : 2956 writes/s
────────────────────────────────────────────────────────

► Waiting for all nodes to converge (timeout 10s)... converged in 2s

► Verifying 6 nodes:
  n1(127.0.0.1:42491)        88706 rows  ✓
  n2(127.0.0.1:36143)        88706 rows  ✓
  n3(127.0.0.1:43541)        88706 rows  ✓
  n4(127.0.0.1:43957)        88706 rows  ✓
  n5(127.0.0.1:41681)        88706 rows  ✓
  n6(127.0.0.1:44099)        88706 rows  ✓

✓  All 6 nodes consistent: 88706 rows confirmed on every node.
```

**0 failed writes. All 6 nodes converged to the same 88,706 rows.**

Throughput drops from 4,289 (3-node) to 2,956 (6-node) as the majority requirement grows from 2 to 4 nodes — the expected quorum cost.

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
  n1  →  127.0.0.1:39343
  n2  →  127.0.0.1:33367
  n3  →  127.0.0.1:40719
  n4  →  127.0.0.1:37731
  n5  →  127.0.0.1:43003
  n6  →  127.0.0.1:40333
  n7  →  127.0.0.1:36205
  n8  →  127.0.0.1:46733
  n9  →  127.0.0.1:42499
► Waiting for leader  →  leader: n5(127.0.0.1:43003)
► Hammering  writers=20  duration=30s  nodes=9
  (writes spread round-robin across all nodes — followers forward to leader)

────────────────────────────────────────────────────────
  Write phase complete
  Duration   : 30.0s
  Written    : 62704
  Failed     : 0
  Throughput : 2087 writes/s
────────────────────────────────────────────────────────

► Waiting for all nodes to converge (timeout 10s)... converged in 2s

► Verifying 9 nodes:
  n1..n9   62704 rows each  ✓

✓  All 9 nodes consistent: 62704 rows confirmed on every node.
```

**0 failed writes. All 9 nodes converged to the same 62,704 rows.**

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
  n1  →  127.0.0.1:41111   n2  →  127.0.0.1:41765
  n3  →  127.0.0.1:42211   n4  →  127.0.0.1:44177
  n5  →  127.0.0.1:35899   n6  →  127.0.0.1:33819
  n7  →  127.0.0.1:33963   n8  →  127.0.0.1:39285
  n9  →  127.0.0.1:34091   n10 →  127.0.0.1:38483
  n11 →  127.0.0.1:38373   n12 →  127.0.0.1:35617
► Waiting for leader  →  leader: n2(127.0.0.1:41765)
► Hammering  writers=20  duration=30s  nodes=12
  (writes spread round-robin across all nodes — followers forward to leader)

────────────────────────────────────────────────────────
  Write phase complete
  Duration   : 30.0s
  Written    : 34650
  Failed     : 0
  Throughput : 1154 writes/s
────────────────────────────────────────────────────────

► Waiting for all nodes to converge (timeout 10s)... converged in 2s

► Verifying 12 nodes:
  n1..n12   34650 rows each  ✓

✓  All 12 nodes consistent: 34650 rows confirmed on every node.
```

**0 failed writes. All 12 nodes converged to the same 34,650 rows.**

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
  n1  →  127.0.0.1:33557   n2  →  127.0.0.1:45979
  n3  →  127.0.0.1:38669   n4  →  127.0.0.1:36767
  n5  →  127.0.0.1:43413   n6  →  127.0.0.1:35333
  n7  →  127.0.0.1:36437   n8  →  127.0.0.1:33017
  n9  →  127.0.0.1:35207   n10 →  127.0.0.1:39791
  n11 →  127.0.0.1:41817   n12 →  127.0.0.1:33457
  n13 →  127.0.0.1:42675   n14 →  127.0.0.1:33447
  n15 →  127.0.0.1:46615
► Waiting for leader  →  leader: n14(127.0.0.1:33447)
► Hammering  writers=20  duration=30s  nodes=15
  (writes spread round-robin across all nodes — followers forward to leader)

────────────────────────────────────────────────────────
  Write phase complete
  Duration   : 30.0s
  Written    : 27032
  Failed     : 0
  Throughput : 900 writes/s
────────────────────────────────────────────────────────

► Waiting for all nodes to converge (timeout 10s)... converged in 2s

► Verifying 15 nodes:
  n1..n15   27032 rows each  ✓

✓  All 15 nodes consistent: 27032 rows confirmed on every node.
```

**0 failed writes. All 15 nodes converged to the same 27,032 rows.**

---

## Summary

| Nodes | Quorum | Written  | Failed | Throughput  | Consistent |
|-------|--------|----------|--------|-------------|------------|
| 3     | 2      | 128,880  | 0      | 4,289 w/s   | ✓          |
| 6     | 4      | 88,706   | 0      | 2,956 w/s   | ✓          |
| 9     | 5      | 62,704   | 0      | 2,087 w/s   | ✓          |
| 12    | 7      | 34,650   | 0      | 1,154 w/s   | ✓          |
| 15    | 8      | 27,032   | 0      | 900 w/s     | ✓          |

Throughput scales down with quorum size as expected: each additional majority node adds one more round-trip per write commit.
