require "./spec_helper"

private def sql_db_of(db : DB::Database) : SQL::Database
  cnn = db.checkout
  (cnn.as(TrashPandaDB::Connection)).sql_db
ensure
  cnn.release if cnn
end

describe "EXPLAIN" do
  it "returns a plan string for a full scan" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      rows = db.query_all "EXPLAIN SELECT * FROM t", as: String
      rows.size.should eq 1
      rows.first.should contain "scan"
    end
  end

  it "shows PK lookup when WHERE is on PK" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      rows = db.query_all "EXPLAIN SELECT * FROM t WHERE id = 1", as: String
      rows.first.downcase.should contain "pk lookup"
    end
  end

  it "shows index scan when a secondary index is used" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "CREATE INDEX idx_v ON t(v)"
      rows = db.query_all "EXPLAIN SELECT * FROM t WHERE v = 'hello'", as: String
      rows.any? { |r| r.downcase.includes?("index") }.should be_true
    end
  end

  it "EXPLAIN QUERY PLAN is accepted as an alias" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      rows = db.query_all "EXPLAIN QUERY PLAN SELECT * FROM t", as: String
      rows.size.should be > 0
    end
  end
end

describe "Metrics counters" do
  it "queries_total increments per execute call" do
    with_mem_db do |db|
      sdb = sql_db_of(db)
      before = sdb.queries_total
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
      db.exec "INSERT INTO t (id) VALUES (1)"
      db.scalar "SELECT COUNT(*) FROM t"
      sdb.queries_total.should eq before + 3
    end
  end

  it "writes_total counts only DML/DDL" do
    with_mem_db do |db|
      sdb = sql_db_of(db)
      before = sdb.writes_total
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
      db.exec "INSERT INTO t (id) VALUES (1)"
      db.scalar "SELECT COUNT(*) FROM t"
      sdb.writes_total.should eq before + 2
    end
  end

  it "slow_queries_total increments when threshold is zero" do
    with_mem_db do |db|
      sdb = sql_db_of(db)
      before = sdb.slow_queries_total
      ENV["TPDB_SLOW_QUERY_MS"] = "0"
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
      sdb.slow_queries_total.should be > before
    ensure
      ENV.delete("TPDB_SLOW_QUERY_MS")
    end
  end

  it "slow_queries_total does not increment for fast queries with high threshold" do
    with_mem_db do |db|
      sdb = sql_db_of(db)
      ENV["TPDB_SLOW_QUERY_MS"] = "999999"
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
      db.scalar "SELECT 1"
      sdb.slow_queries_total.should eq 0
    ensure
      ENV.delete("TPDB_SLOW_QUERY_MS")
    end
  end
end
