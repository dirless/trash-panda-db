require "./spec_helper"

describe "Pre-migration row compatibility (ALTER TABLE ADD COLUMN)" do
  # Rows stored before ALTER TABLE ADD COLUMN have fewer elements than the
  # current schema. All query paths must handle this gracefully by treating
  # the missing columns as NULL.

  it "SELECT * returns nil for added columns on old rows" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'hello')"
      db.exec "ALTER TABLE t ADD COLUMN extra TEXT"
      db.exec "INSERT INTO t VALUES (2, 'world', 'new')"

      ids = [] of Int64
      extras = [] of String?
      db.query_each("SELECT id, extra FROM t ORDER BY id") do |rs|
        ids << rs.read(Int64)
        extras << rs.read(String?)
      end
      ids.should eq([1_i64, 2_i64])
      extras[0].should be_nil   # old row: extra is nil
      extras[1].should eq("new")
    end
  end

  it "WHERE clause with column added after row creation returns nil (NULL semantics)" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'old')"
      db.exec "ALTER TABLE t ADD COLUMN score INTEGER"
      db.exec "INSERT INTO t VALUES (2, 'new', 100)"

      # Old row: score IS NULL — should NOT match score > 50
      results = [] of Int64
      db.query_each("SELECT id FROM t WHERE score > 50") do |rs|
        results << rs.read(Int64)
      end
      results.should eq([2_i64])  # only new row with score=100 matches
    end
  end

  it "specific column reference returns nil for pre-migration rows" do
    with_mem_db do |db|
      db.exec "CREATE TABLE nodes (id INTEGER, name TEXT)"
      db.exec "INSERT INTO nodes VALUES (1, 'n1')"
      db.exec "ALTER TABLE nodes ADD COLUMN cpu_count INTEGER"
      db.exec "ALTER TABLE nodes ADD COLUMN memory_gb INTEGER"

      cpu = db.query_one("SELECT cpu_count FROM nodes WHERE id = 1", as: Int64?)
      cpu.should be_nil
    end
  end
end

describe "ORDER BY after ALTER TABLE (migration compatibility)" do
  # Regression test for IndexError: rows stored before ALTER TABLE ADD COLUMN
  # had fewer elements than the current schema. ORDER BY used to call a[col_idx]
  # with the current-schema index on old rows, crashing with IndexError.
  # Fix: use a[col_idx]? (safe nil-returning access).

  it "sorts rows with pre-migration rows that have fewer columns than current schema" do
    with_mem_db do |db|
      db.exec "CREATE TABLE hc (id INTEGER PRIMARY KEY, customer_id TEXT, checked_at TEXT)"
      db.exec "INSERT INTO hc (id, customer_id, checked_at) VALUES (1, 'c1', '2026-01-01T10:00:00Z')"
      db.exec "INSERT INTO hc (id, customer_id, checked_at) VALUES (2, 'c1', '2026-01-01T09:00:00Z')"

      # Simulate ALTER TABLE ADD COLUMN (adds columns after the rows were stored)
      db.exec "ALTER TABLE hc ADD COLUMN data_updated_at TEXT"
      db.exec "ALTER TABLE hc ADD COLUMN active_agents INTEGER"

      # This used to crash with IndexError: Array#[] out of bounds
      # because old rows have 3 elements but the current schema col index
      # for 'checked_at' was recalculated as if it came after the new columns.
      row = db.query_one(
        "SELECT id, customer_id, checked_at FROM hc WHERE customer_id = 'c1' ORDER BY checked_at DESC LIMIT 1",
        as: {Int64, String, String}
      )
      # Should return the most recent row first
      row[0].should eq(1_i64)
      row[2].should eq("2026-01-01T10:00:00Z")
    end
  end

  it "ORDER BY on table with 3 rounds of ALTER TABLE ADD COLUMN" do
    with_mem_db do |db|
      db.exec "CREATE TABLE events (id INTEGER PRIMARY KEY, ts TEXT)"
      db.exec "INSERT INTO events VALUES (1, '2026-05-01')"
      db.exec "INSERT INTO events VALUES (2, '2026-05-03')"
      db.exec "INSERT INTO events VALUES (3, '2026-05-02')"

      db.exec "ALTER TABLE events ADD COLUMN col_a TEXT"
      db.exec "ALTER TABLE events ADD COLUMN col_b TEXT"
      db.exec "ALTER TABLE events ADD COLUMN col_c TEXT"

      # Insert a new row that has all columns
      db.exec "INSERT INTO events VALUES (4, '2026-05-04', 'a', 'b', 'c')"

      ids = [] of Int64
      db.query_each("SELECT id FROM events ORDER BY ts DESC") do |rs|
        ids << rs.read(Int64)
      end
      ids.should eq([4_i64, 2_i64, 3_i64, 1_i64])
    end
  end
end
