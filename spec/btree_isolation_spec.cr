require "./spec_helper"

# Regression specs for btree leaf-chain integrity across tables.
# The production ops.db had health_checks leaf pages linked into the nodes
# btree via leaf_next pointers, causing a scan of nodes to return
# health_check rows decoded under the nodes schema.
#
# These specs exercise the conditions that produce cross-table leaf-chain
# corruption: heavy interleaved INSERT/DELETE across multiple tables with
# wide rows that trigger btree splits.

BTREE_ISO_DB = "./test_btree_iso.tpdb"

private def cleanup_iso_db
  File.delete(BTREE_ISO_DB) rescue nil
  File.delete("#{BTREE_ISO_DB}-wal") rescue nil
end

private def open_iso_db(&block : DB::Database ->)
  cleanup_iso_db
  DB.open "trashpanda:#{BTREE_ISO_DB}", &block
ensure
  cleanup_iso_db
end

private def sql_db_of(db : DB::Database) : TrashPandaDB::SQL::Database
  cnn = db.checkout
  (cnn.as(TrashPandaDB::Connection)).sql_db
ensure
  cnn.release if cnn
end

describe "BTree leaf-chain isolation" do
  it "scan of table A never returns rows from table B" do
    with_mem_db do |db|
      db.exec "CREATE TABLE nodes (id INTEGER PRIMARY KEY, name TEXT NOT NULL, ip TEXT NOT NULL)"
      db.exec "CREATE TABLE health_checks (id INTEGER PRIMARY KEY, node_id INTEGER, status TEXT, response_time_ms INTEGER)"

      db.exec "INSERT INTO nodes (name, ip) VALUES ('worker-01', '10.0.0.1')"
      db.exec "INSERT INTO nodes (name, ip) VALUES ('worker-02', '10.0.0.2')"

      # Insert enough health_checks to fill multiple leaf pages
      200.times do |i|
        db.exec "INSERT INTO health_checks (node_id, status, response_time_ms) VALUES (?, 'up', ?)",
          (i % 2 + 1), i
      end

      # Now prune most health_checks — this exercises delete_from_leaf
      db.exec "DELETE FROM health_checks WHERE id > 20"

      # Insert more health_checks to trigger splits on pages that were
      # previously freed (if free-list reuse is involved)
      200.times do |i|
        db.exec "INSERT INTO health_checks (node_id, status, response_time_ms) VALUES (?, 'up', ?)",
          (i % 2 + 1), i + 1000
      end

      # Verify: nodes scan returns exactly 2 rows with correct types
      node_rows = db.query_all "SELECT id, name, ip FROM nodes", as: {Int64, String, String}
      node_rows.size.should eq(2)
      node_rows.each do |id, name, ip|
        id.should be_a(Int64)
        name.should be_a(String)
        ip.should be_a(String)
        name.should start_with("worker-")
      end
    end
  end

  it "scan returns correct rows after heavy interleaved INSERT/DELETE cycles" do
    with_mem_db do |db|
      db.exec "CREATE TABLE small (id INTEGER PRIMARY KEY, val TEXT NOT NULL)"
      db.exec "CREATE TABLE big (id INTEGER PRIMARY KEY, payload TEXT, owner_id INTEGER)"

      # Seed the small table
      5.times { |i| db.exec "INSERT INTO small (val) VALUES (?)", "item-#{i}" }

      # Run multiple rounds: insert many rows into big, then delete most of them
      5.times do |round|
        300.times do |i|
          db.exec "INSERT INTO big (payload, owner_id) VALUES (?, ?)",
            "payload-round#{round}-#{i}-#{("x" * 50)}", i % 5
        end
        db.exec "DELETE FROM big WHERE id > ?", (round * 300 + 10)
      end

      # Verify small table is intact
      small_rows = db.query_all "SELECT id, val FROM small ORDER BY id", as: {Int64, String}
      small_rows.size.should eq(5)
      small_rows.each_with_index do |(id, val), i|
        val.should eq("item-#{i}")
      end

      # Verify big table only has surviving rows
      big_count = db.scalar("SELECT COUNT(*) FROM big").as(Int64)
      big_count.should be > 0
      # All surviving payload values should start with "payload-"
      db.query_all("SELECT payload FROM big LIMIT 50", as: String).each do |p|
        p.should start_with("payload-")
      end
    end
  end

  it "file-backed DB survives restart with multiple tables and pruning" do
    cleanup_iso_db

    # Phase 1: create and populate
    DB.open "trashpanda:#{BTREE_ISO_DB}" do |db|
      db.exec "CREATE TABLE nodes (id INTEGER PRIMARY KEY, name TEXT NOT NULL, ip TEXT NOT NULL)"
      db.exec "CREATE TABLE checks (id INTEGER PRIMARY KEY, node_id INTEGER, status TEXT, ms INTEGER)"

      db.exec "INSERT INTO nodes (name, ip) VALUES ('n1', '1.2.3.4')"
      db.exec "INSERT INTO nodes (name, ip) VALUES ('n2', '5.6.7.8')"

      500.times do |i|
        db.exec "INSERT INTO checks (node_id, status, ms) VALUES (?, 'up', ?)",
          (i % 2 + 1), i
      end

      # Prune
      db.exec "DELETE FROM checks WHERE id > 50"

      # Re-insert to stress free-list
      500.times do |i|
        db.exec "INSERT INTO checks (node_id, status, ms) VALUES (?, 'up', ?)",
          (i % 2 + 1), i + 5000
      end
    end

    # Phase 2: reopen and verify
    DB.open "trashpanda:#{BTREE_ISO_DB}" do |db|
      nodes = db.query_all "SELECT id, name, ip FROM nodes ORDER BY id", as: {Int64, String, String}
      nodes.size.should eq(2)
      nodes.map(&.[1]).should eq(["n1", "n2"])

      statuses = db.query_all "SELECT DISTINCT status FROM checks", as: String
      statuses.should eq(["up"])
    end

    cleanup_iso_db
  end

  it "wide rows causing splits do not corrupt other tables' leaf chains" do
    with_mem_db do |db|
      db.exec "CREATE TABLE meta (id INTEGER PRIMARY KEY, key TEXT NOT NULL, value TEXT NOT NULL)"
      db.exec "CREATE TABLE events (id INTEGER PRIMARY KEY, data TEXT NOT NULL)"

      db.exec "INSERT INTO meta (key, value) VALUES ('version', '1.0')"
      db.exec "INSERT INTO meta (key, value) VALUES ('status', 'ok')"

      # Insert wide rows into events to force many page splits
      100.times do |i|
        db.exec "INSERT INTO events (data) VALUES (?)", "event-#{i}-#{"x" * 200}"
      end

      # Delete most events to free pages
      db.exec "DELETE FROM events WHERE id > 10"

      # Re-insert to potentially reuse freed pages
      100.times do |i|
        db.exec "INSERT INTO events (data) VALUES (?)", "event-v2-#{i}-#{"y" * 200}"
      end

      # meta table should be untouched
      meta = db.query_all "SELECT key, value FROM meta ORDER BY key", as: {String, String}
      meta.should eq([{"status", "ok"}, {"version", "1.0"}])
    end
  end

  it "UPDATE on one table does not leak rows into another" do
    with_mem_db do |db|
      db.exec "CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"
      db.exec "CREATE TABLE b (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"

      3.times { |i| db.exec "INSERT INTO a (name) VALUES (?)", "a-#{i}" }
      50.times { |i| db.exec "INSERT INTO b (name) VALUES (?)", "b-#{i}-#{"z" * 100}" }

      # Update all rows in b (forces delete+insert per row)
      db.exec "UPDATE b SET name = name || '-updated'"

      # Table a should be unchanged
      a_rows = db.query_all "SELECT id, name FROM a ORDER BY id", as: {Int64, String}
      a_rows.size.should eq(3)
      a_rows.map(&.[1]).should eq(["a-0", "a-1", "a-2"])

      # Table b should have all 50 rows with updated names
      b_rows = db.query_all "SELECT id, name FROM b ORDER BY id", as: {Int64, String}
      b_rows.size.should eq(50)
      b_rows.each do |id, name|
        name.should match(/^b-\d+-z+-updated$/)
      end
    end
  end

  it "ALTER TABLE ADD COLUMN rewriting rows does not corrupt other tables" do
    with_mem_db do |db|
      db.exec "CREATE TABLE targets (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"
      db.exec "CREATE TABLE logs (id INTEGER PRIMARY KEY, msg TEXT NOT NULL)"

      db.exec "INSERT INTO targets (name) VALUES ('t1')"
      db.exec "INSERT INTO targets (name) VALUES ('t2')"

      100.times { |i| db.exec "INSERT INTO logs (msg) VALUES (?)", "log-#{i}-#{"p" * 80}" }

      # ALTER TABLE ADD COLUMN rewrites every row in targets via update = delete + insert
      db.exec "ALTER TABLE targets ADD COLUMN status TEXT DEFAULT 'active'"

      # Verify targets got the new column
      targets = db.query_all "SELECT id, name, status FROM targets ORDER BY id", as: {Int64, String, String}
      targets.size.should eq(2)
      targets.each { |_, _, status| status.should eq("active") }

      # Verify logs are untouched
      log_count = db.scalar("SELECT COUNT(*) FROM logs").as(Int64)
      log_count.should eq(100)

      first_log = db.query_one("SELECT msg FROM logs WHERE id = 1", as: String)
      first_log.should start_with("log-0-")
    end
  end
end
