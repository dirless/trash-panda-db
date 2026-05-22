# Plan

## Open items

| # | Severity | Description |
|---|----------|-------------|
| 17 | HIGH | `ALTER TABLE` — add/drop/rename column |
| 18 | HIGH | SQL completeness — `IN (subquery)`, `UPDATE … FROM`, `DELETE … USING`, `RETURNING` |
| 19 | MEDIUM | Window functions — `ROW_NUMBER`, `RANK`, `LAG`, `LEAD`, `OVER` |
| 20 | MEDIUM | Operational tooling — `EXPLAIN`, slow-query log, metrics endpoint |

---

## Item 17 — `ALTER TABLE` support [HIGH]

**Files:** `src/trash_panda_db/sql/` (parser, AST, database, catalog)

**Scope:**
No DDL beyond `CREATE TABLE` / `CREATE INDEX` / `DROP TABLE` exists today. Any schema
change requires a drop-and-recreate cycle, which is unworkable for a production app
shipping schema migrations. Minimum viable set:

- `ALTER TABLE t ADD COLUMN col type [NOT NULL] [DEFAULT expr]`
- `ALTER TABLE t DROP COLUMN col`
- `ALTER TABLE t RENAME COLUMN old TO new`
- `ALTER TABLE t RENAME TO new_name`

**Fix sketch:**

1. **Parser** — add an `ALTER TABLE` branch in the statement parser. Each sub-command
   (`ADD COLUMN`, `DROP COLUMN`, `RENAME COLUMN`, `RENAME TO`) maps to a distinct AST
   node variant.

2. **Catalog** — `Table` stores the column list in the btree catalog page. `ADD COLUMN`
   appends to the schema; `DROP COLUMN` removes it; `RENAME` updates it in place.
   All changes must be written atomically (WAL-protected write to the catalog page).

3. **Data migration** — `ADD COLUMN` with a `DEFAULT` must back-fill existing rows, or
   the executor must synthesise the default at read time for rows written before the
   migration. The latter is cheaper and avoids a full-table rewrite; store a
   `column_added_at_rowid` watermark in the catalog.

4. **Index invalidation** — `DROP COLUMN` must refuse (or cascade-drop) any index that
   covers the removed column.

5. **Spec coverage** — round-trip migrations: create table, insert rows, alter, re-query,
   verify schema and data integrity.

---

## Item 18 — SQL completeness for production [HIGH]

**Files:** `src/trash_panda_db/sql/` (parser, AST, database)

**Scope:**
Four constructs that regularly appear in production CRUD apps and are not yet supported:

### 18a — `IN (subquery)`

```sql
SELECT * FROM orders WHERE customer_id IN (SELECT id FROM customers WHERE active = 1)
```

**Fix sketch:** The parser already handles `IN (val, val, …)`; extend it to accept a
`SELECT` statement as the RHS. The executor evaluates the subquery first, collects the
result column into a `Set`, then runs the outer query filtering with `Set#includes?`.

### 18b — `UPDATE … FROM`

```sql
UPDATE orders SET status = 'shipped'
FROM shipments
WHERE orders.id = shipments.order_id AND shipments.dispatched_at IS NOT NULL
```

**Fix sketch:** Add an optional `FROM table [JOIN …] [WHERE …]` clause to the `UPDATE`
AST node. The executor builds a join result set, then applies updates to matching rows
in the target table identified by rowid.

### 18c — `DELETE … USING`

```sql
DELETE FROM sessions USING users
WHERE sessions.user_id = users.id AND users.banned = 1
```

**Fix sketch:** Mirror the `UPDATE … FROM` approach: optional `USING` clause in `DELETE`
AST; join to find target rowids, then delete them.

### 18d — `RETURNING`

```sql
INSERT INTO items (name) VALUES ('foo') RETURNING id, name
UPDATE items SET name = 'bar' WHERE id = 1 RETURNING *
```

**Fix sketch:** Add an optional `RETURNING col_list` clause to `INSERT`, `UPDATE`, and
`DELETE` AST nodes. After applying the mutation, project the requested columns from the
affected rows and return them as a `QueryResult` instead of an `ExecResult`. The
crystal-db adapter already supports this via `DB::ResultSet`.

---

## Item 19 — Window functions [MEDIUM]

**Files:** `src/trash_panda_db/sql/` (parser, AST, database)

**Scope:**
Window functions (`ROW_NUMBER`, `RANK`, `DENSE_RANK`, `LAG`, `LEAD`, `FIRST_VALUE`,
`LAST_VALUE`, `SUM OVER`, `AVG OVER`) are required for analytics queries and reporting
dashboards. They are the most complex SQL feature not yet present.

**Fix sketch:**

1. **Parser** — recognise `func() OVER (PARTITION BY … ORDER BY … [frame])` syntax.
   Store as a `WindowExpr` AST node distinct from aggregate functions.

2. **AST** — `WindowExpr` carries: function name, `PARTITION BY` columns, `ORDER BY`
   columns + directions, optional frame clause (`ROWS`/`RANGE BETWEEN …`).

3. **Executor** — window evaluation runs as a post-projection pass over the full result
   set (after `WHERE` / `JOIN`, before `LIMIT`):
   - Partition the row list by the `PARTITION BY` key.
   - Within each partition, sort by `ORDER BY`.
   - Compute the window function value for each row; attach to a synthetic column.
   - Replace the `WindowExpr` placeholder in the output row with that value.

   Start with ranking functions (`ROW_NUMBER`, `RANK`, `DENSE_RANK`) as they have no
   frame clause, then add `LAG`/`LEAD` (offset access), then aggregate windows
   (`SUM OVER`, `AVG OVER` with frame support).

4. **Spec coverage** — at minimum: `ROW_NUMBER() OVER (PARTITION BY … ORDER BY …)`,
   `LAG(col, 1) OVER (ORDER BY …)`, `SUM(col) OVER (PARTITION BY …)`.

---

## Item 20 — Operational tooling [MEDIUM]

**Files:** `src/trashpandadb.cr`, `src/trash_panda_db/sql/database.cr`

**Scope:**
Three capabilities needed before running TPDB in production without flying blind:

### 20a — `EXPLAIN`

```sql
EXPLAIN SELECT * FROM orders WHERE customer_id = 42
```

**Fix sketch:** Add an `EXPLAIN` statement to the parser. The executor does not run the
query; instead it returns a single-column `QueryResult` describing the plan: which index
(if any) is used, estimated row count, scan type (`PK lookup`, `index scan`, `full scan`).
No optimizer changes needed — just expose what the executor already decides.

### 20b — Slow-query log

**Fix sketch:** Wrap `Database#execute` in a timing block. If the elapsed time exceeds a
configurable threshold (default 100 ms, settable via env var `TPDB_SLOW_QUERY_MS`), emit
a structured STDERR line:

```
[SLOW] 143ms  SELECT * FROM orders WHERE status = 'pending'
```

This requires no new dependencies and costs a single `Time.measure` call per query.

### 20c — Metrics endpoint

**Fix sketch:** Add a `{"action":"metrics"}` handler to `handle_client` in
`trashpandadb.cr`. It returns a JSON object with:

```json
{
  "queries_total": 12345,
  "writes_total": 9876,
  "slow_queries_total": 3,
  "commit_index": 9877,
  "last_applied": 9877,
  "role": "Leader",
  "term": 4,
  "peers": { "n2": { "match": 9877 }, ... }
}
```

Counters are `Atomic(Int64)` fields incremented on each operation; no locking needed.
The endpoint is compatible with a Prometheus text-format scraper wrapper if needed later.
