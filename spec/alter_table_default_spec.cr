require "./spec_helper"

describe "ALTER TABLE ADD COLUMN NOT NULL DEFAULT — pre-migration row semantics" do
  # SQLite semantics: when a column is added via ALTER TABLE ADD COLUMN with
  # NOT NULL DEFAULT x, existing rows (stored before the ALTER TABLE) behave
  # as if they have the default value stored. TrashPandaDB must match this.

  it "returns INTEGER DEFAULT value for pre-migration rows via specific column SELECT" do
    with_mem_db do |db|
      db.exec "CREATE TABLE nodes (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"
      db.exec "INSERT INTO nodes VALUES (1, 'node-1')"
      db.exec "INSERT INTO nodes VALUES (2, 'node-2')"

      # Simulate ALTER TABLE ADD COLUMN (as done in production migrations)
      db.exec "ALTER TABLE nodes ADD COLUMN probe_failure_count INTEGER NOT NULL DEFAULT 0"

      # Insert a new row with the column present
      db.exec "INSERT INTO nodes VALUES (3, 'node-3', 5)"

      # Old rows should return DEFAULT 0, not nil
      counts = [] of Int32?
      db.query_each("SELECT probe_failure_count FROM nodes ORDER BY id") do |rs|
        counts << rs.read(Int32?)
      end
      counts.should eq([0, 0, 5])
    end
  end

  it "returns INTEGER DEFAULT value for SELECT * on pre-migration rows" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'hello')"
      db.exec "ALTER TABLE t ADD COLUMN counter INTEGER NOT NULL DEFAULT 42"

      row = db.query_one("SELECT id, val, counter FROM t WHERE id = 1", as: {Int64, String, Int64})
      row[2].should eq(42_i64)
    end
  end

  it "returns TEXT DEFAULT value for pre-migration rows" do
    with_mem_db do |db|
      db.exec "CREATE TABLE items (id INTEGER PRIMARY KEY)"
      db.exec "INSERT INTO items VALUES (1)"
      db.exec "ALTER TABLE items ADD COLUMN status TEXT NOT NULL DEFAULT 'pending'"

      status = db.query_one("SELECT status FROM items WHERE id = 1", as: String)
      status.should eq("pending")
    end
  end

  it "nullable column without DEFAULT returns nil for pre-migration rows" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
      db.exec "INSERT INTO t VALUES (1)"
      db.exec "ALTER TABLE t ADD COLUMN optional TEXT"

      val = db.query_one("SELECT optional FROM t WHERE id = 1", as: String?)
      val.should be_nil
    end
  end

  it "WHERE clause uses DEFAULT value for pre-migration rows with NOT NULL DEFAULT" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'old')"
      db.exec "INSERT INTO t VALUES (2, 'newer')"
      db.exec "ALTER TABLE t ADD COLUMN score INTEGER NOT NULL DEFAULT 0"
      db.exec "INSERT INTO t VALUES (3, 'new', 100)"

      # old rows have score = 0 (default) — should NOT match score > 50
      results = [] of Int64
      db.query_each("SELECT id FROM t WHERE score > 50") do |rs|
        results << rs.read(Int64)
      end
      results.should eq([3_i64])
    end
  end

  it "ORDER BY uses DEFAULT value for pre-migration rows" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'a')"
      db.exec "INSERT INTO t VALUES (2, 'b')"
      db.exec "ALTER TABLE t ADD COLUMN priority INTEGER NOT NULL DEFAULT 5"
      db.exec "INSERT INTO t VALUES (3, 'c', 10)"
      db.exec "INSERT INTO t VALUES (4, 'd', 1)"

      ids = [] of Int64
      db.query_each("SELECT id FROM t ORDER BY priority ASC") do |rs|
        ids << rs.read(Int64)
      end
      # priority: 1(row4), 5(row1), 5(row2), 10(row3) — stable sort within ties
      ids[0].should eq(4_i64)
      ids[3].should eq(3_i64)
    end
  end

  it "SELECT * pads pre-migration rows with DEFAULT values" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'old')"
      db.exec "ALTER TABLE t ADD COLUMN active INTEGER NOT NULL DEFAULT 1"
      db.exec "INSERT INTO t VALUES (2, 'new', 0)"

      ids = [] of Int64
      actives = [] of Int64
      db.query_each("SELECT id, name, active FROM t ORDER BY id") do |rs|
        ids << rs.read(Int64)
        rs.read(String)  # name
        actives << rs.read(Int64)
      end
      ids.should eq([1_i64, 2_i64])
      actives[0].should eq(1_i64)  # old row: DEFAULT 1
      actives[1].should eq(0_i64)  # new row: explicitly set 0
    end
  end

  it "emulates Granite-style: non-nilable Int32 column with default on pre-migration row" do
    # This test reproduces the production issue:
    # probe_failure_count INTEGER NOT NULL DEFAULT 0 was added via ALTER TABLE.
    # Old nodes (pre-migration) have no value for it. TPDB must return 0, not nil.
    # Without this fix, result_set.read(Int32) → read(Int64) fails with
    # ColumnTypeMismatchError because nil.is_a?(Int64) is false.
    with_mem_db do |db|
      db.exec "CREATE TABLE nodes (id INTEGER PRIMARY KEY, name TEXT, ip TEXT)"
      db.exec "INSERT INTO nodes VALUES (1, 'prod-eu-01', '1.2.3.4')"
      db.exec "ALTER TABLE nodes ADD COLUMN probe_failure_count INTEGER NOT NULL DEFAULT 0"

      # This must NOT raise ColumnTypeMismatchError
      count = db.query_one("SELECT probe_failure_count FROM nodes WHERE id = 1", as: Int32)
      count.should eq(0)
    end
  end

  it "emulates Granite-style: Bool column with NOT NULL DEFAULT 1 on pre-migration row" do
    # email_verified INTEGER NOT NULL DEFAULT 1 was added via ALTER TABLE to customer_accounts.
    # Old accounts have no value for it. TPDB must return 1 (true), not nil.
    with_mem_db do |db|
      db.exec "CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT)"
      db.exec "INSERT INTO accounts VALUES (1, 'user@example.com')"
      db.exec "ALTER TABLE accounts ADD COLUMN email_verified INTEGER NOT NULL DEFAULT 1"

      val = db.query_one("SELECT email_verified FROM accounts WHERE id = 1", as: Int64)
      val.should eq(1_i64)
    end
  end
end
