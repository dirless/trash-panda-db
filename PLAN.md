# Plan: dirless-backend SQLite → TrashPandaDB migration

## Context

`dirless-backend` (`/home/labros/git_work/dirless-backend`) currently uses SQLite via
`crystal-lang/crystal-sqlite3`. The goal is to replace it with TrashPandaDB so the backend
has zero C dependencies.

Most SQL features used by dirless already work (PRAGMAs, strftime, COALESCE in UPDATE,
INSERT OR IGNORE, ON CONFLICT DO UPDATE with literal/param SET values, JOINs). Two features
are missing from TrashPandaDB and must be added first.

---

## Phase 1 — Add missing features to trash-panda-db

### Step 1: `excluded.col` in ON CONFLICT DO UPDATE

**Why:** `settings.cr` and `leases.cr` in dirless use `excluded.col` to reference the
would-be-inserted row values in the SET clause, e.g.:

```sql
INSERT INTO settings (key, value) VALUES (?, ?)
ON CONFLICT (key) DO UPDATE SET
  value      = excluded.value,
  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
```

**Where to implement:**

- `src/trash_panda_db/sql/parser.cr` — `parse_insert` already collects `on_conflict_updates`
  as `Array(Tuple(String, Expr))`. The SET expressions are parsed by `parse_expr`. Currently
  `excluded.col` would parse fine as `AST::ColRef(tbl="excluded", col="value")` — confirm
  this already parses correctly, since qualified colrefs like `tbl.col` are handled in
  `parse_primary`.

- `src/trash_panda_db/sql/database.cr` — `exec_insert`, in the upsert branch (~line 430):
  when evaluating `on_conflict_updates`, call `eval_expr(val_expr, existing_row, schema, binder)`.
  Currently this uses the existing row for context. For `excluded.col`, we need to resolve
  `ColRef(tbl="excluded", col)` against the *insert* row instead.

  Concrete fix: build an `excluded_row : Row` from the insert column list + values before
  the conflict check, then pass it into a modified eval that maps `excluded.X` → `excluded_row[col_idx]`.
  Simplest approach: in `eval_col_ref`, check `expr.tbl == "excluded"` and look up `col` in
  the insert schema / column list, returning the value from `excluded_row`.

  The `exec_insert` upsert path already has access to both the existing row (`existing`) and
  the incoming values (`vals`). Build `excluded_row` by aligning `vals` with `col_names` and
  filling defaults/nils for omitted columns.

**Spec to add in `spec/dirless_compat_spec.cr`:**

```crystal
it "ON CONFLICT DO UPDATE with excluded.col reference" do
  DB.open("trashpanda::memory:") do |db|
    db.exec "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT)"
    db.exec "INSERT INTO settings (key, value) VALUES ('x', 'old')"
    db.exec <<-SQL, "new"
      INSERT INTO settings (key, value) VALUES ('x', ?)
      ON CONFLICT (key) DO UPDATE SET value = excluded.value
    SQL
    v = db.scalar("SELECT value FROM settings WHERE key = 'x'").as(String)
    v.should eq "new"
  end
end
```

---

### Step 2: Table-qualified star (`t.*`) in SELECT

**Why:** The membership JOIN queries in dirless select only one side of the join:

```sql
SELECT g.* FROM groups g JOIN group_memberships gm ON gm.group_id = g.id
WHERE gm.user_id = ? AND gm.deleted_at IS NULL AND g.deleted_at IS NULL
ORDER BY g.gid

SELECT u.* FROM users u JOIN group_memberships gm ON gm.user_id = u.id
WHERE gm.group_id = ? AND gm.deleted_at IS NULL AND u.deleted_at IS NULL
ORDER BY u.uid
```

After TrashPandaDB builds its joined schema, every column is prefixed: `g.id`, `g.name`,
`gm.user_id`, etc. `SELECT g.*` must expand to only the `g.`-prefixed columns, in order.

**Where to implement:**

- `src/trash_panda_db/sql/ast.cr` — Give `AST::Star` an optional table qualifier, or add a
  new `AST::QualifiedStar` class with a `tbl : String` field.

- `src/trash_panda_db/sql/parser.cr` — In `parse_select_cols`, when parsing `ident.*`, emit
  `AST::QualifiedStar.new(tbl)` (or `Star.new(tbl)`) instead of a bare `Star`.

- `src/trash_panda_db/sql/database.cr` — In `project_cols` (~line 1340), handle `QualifiedStar`
  by filtering `schema.cols` to those whose name starts with `"#{tbl}."`, returning those
  column values from the row. Also update `sel_col_name` to return something sensible
  (e.g. the column name after the dot) for result column naming.

**Spec to add:**

```crystal
it "t.* in a JOIN selects only that table's columns" do
  DB.open("trashpanda::memory:") do |db|
    db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
    db.exec "CREATE TABLE memberships (user_id INTEGER, group_id INTEGER)"
    db.exec "INSERT INTO users VALUES (1, 'Alice')"
    db.exec "INSERT INTO memberships VALUES (1, 99)"
    db.query("SELECT u.* FROM users u JOIN memberships m ON m.user_id = u.id WHERE m.group_id = 99") do |rs|
      rs.move_next
      rs.read(Int64).should eq 1_i64
      rs.read(String).should eq "Alice"
    end
  end
end
```

---

## Phase 2 — Migrate dirless-backend

All changes are in `/home/labros/git_work/dirless-backend`.

### Step 3: Swap the dependency

**`shard.yml`** — remove `sqlite3`, add TrashPandaDB. If published to GitHub:

```yaml
trash_panda_db:
  github: dirless/trash-panda-db
  version: "~> 1.1.0"
```

Or use a local path for development:

```yaml
trash_panda_db:
  path: ../trash-panda-db
```

Run `shards install` after editing.

### Step 4: Update `src/dirless/store/db.cr`

```crystal
# Change:
require "sqlite3"
# To:
require "trash_panda_db"
```

```crystal
# Change the URI builder:
uri = path == ":memory:" ? "sqlite3::memory:" : "sqlite3://#{path}"
# To:
uri = path == ":memory:" ? "trashpanda::memory:" : "trashpanda:#{path}"
```

All four PRAGMAs are already accepted as no-ops by TrashPandaDB — no change needed there.

### Step 5: Rewrite `leases.cr` — eliminate `ON CONFLICT DO UPDATE WHERE`

The lease acquisition uses a conditional upsert filter (`WHERE lease.expires_at < ?`) that
is a SQLite extension not worth adding to TrashPandaDB. Since the code already holds a
`BEGIN IMMEDIATE` lock, the check can move into Crystal:

```crystal
def self.acquire(db : DB::Database, syncer_id : String, duration_seconds : Int32 = 30) : Lease?
  now = Time.utc
  now_str = now.to_rfc3339
  expires_at = (now + duration_seconds.seconds).to_rfc3339

  db.exec("BEGIN IMMEDIATE")
  begin
    current_expiry = db.scalar?(
      "SELECT expires_at FROM lease WHERE singleton_lock = 1",
      as: String
    )

    if current_expiry.nil? || current_expiry < now_str
      db.exec <<-SQL, syncer_id, now_str, expires_at
        INSERT INTO lease (singleton_lock, syncer_id, acquired_at, expires_at)
        VALUES (1, ?, ?, ?)
        ON CONFLICT (singleton_lock) DO UPDATE SET
          syncer_id   = excluded.syncer_id,
          acquired_at = excluded.acquired_at,
          expires_at  = excluded.expires_at
      SQL
    end

    row = db.query_one?(
      "SELECT syncer_id, acquired_at, expires_at FROM lease WHERE singleton_lock = 1 AND syncer_id = ?",
      syncer_id,
      as: {String, String, String}
    )
    db.exec("COMMIT")
    row ? Lease.new(*row) : nil
  rescue ex
    db.exec("ROLLBACK") rescue nil
    raise ex
  end
end
```

Note: this still uses `excluded.col` (from Step 1). If Step 1 is not done yet, replace
`excluded.syncer_id` etc. with `?` params and pass the values again.

### Step 6: Verify `settings.cr`

After Step 1, `excluded.value` works as-is. If landing before Step 1, rewrite as:

```crystal
db.exec <<-SQL, key, value, value
  INSERT INTO settings (key, value) VALUES (?, ?)
  ON CONFLICT (key) DO UPDATE SET
    value      = ?,
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
SQL
```

(Pass `value` twice — once for INSERT, once for the UPDATE SET.)

### Step 7: Update health route glob (if file extension changes)

`src/dirless/backend/routes/health.cr` counts tenant DBs via `Dir.glob("*.db")`.
TrashPandaDB doesn't care about extension — you can keep `.db` in the path and it works.
If you rename to `.tpdb`, update the glob here and wherever `tenant.cr` builds the path.

### Step 8: Run the dirless spec suite

```bash
cd /home/labros/git_work/dirless-backend
crystal spec --no-color
```

Watch for:
- Column-order mismatches in `as: {Type, Type, ...}` tuple reads from `SELECT *` — must
  match the CREATE TABLE column order exactly.
- Any `db.scalar` returning a different numeric type (TrashPandaDB always returns Int64
  for integers; dirless already casts `.as(Int64)` so this should be fine).
- The `db.query` block in `agent_heartbeats.cr` — verify `rs.read(String)` column order
  matches the SELECT column order.

---

## File reference

| Repo | File | What changes |
|------|------|-------------|
| trash-panda-db | `src/trash_panda_db/sql/ast.cr` | Add QualifiedStar node (Step 2) |
| trash-panda-db | `src/trash_panda_db/sql/parser.cr` | Parse `t.*`; confirm `excluded.col` parses (Steps 1–2) |
| trash-panda-db | `src/trash_panda_db/sql/database.cr` | Resolve `excluded.col` in upsert eval; expand `t.*` in project_cols (Steps 1–2) |
| trash-panda-db | `spec/dirless_compat_spec.cr` | New specs for Steps 1–2 |
| dirless-backend | `shard.yml` | Swap dependency (Step 3) |
| dirless-backend | `src/dirless/store/db.cr` | require + URI (Step 4) |
| dirless-backend | `src/dirless/store/queries/leases.cr` | Rewrite acquire() (Step 5) |
| dirless-backend | `src/dirless/store/queries/settings.cr` | excluded.value or double-param (Step 6) |
| dirless-backend | `src/dirless/backend/routes/health.cr` | Glob if extension changes (Step 7) |
