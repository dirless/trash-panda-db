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
