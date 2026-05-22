require "./spec_helper"

describe "SELECT DISTINCT" do
  it "deduplicates rows from a full table scan" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, color TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'red')"
      db.exec "INSERT INTO t VALUES (2, 'blue')"
      db.exec "INSERT INTO t VALUES (3, 'red')"
      db.exec "INSERT INTO t VALUES (4, 'blue')"
      db.exec "INSERT INTO t VALUES (5, 'green')"

      rows = db.query_all("SELECT DISTINCT color FROM t", as: String)
      rows.sort.should eq ["blue", "green", "red"]
    end
  end

  it "returns all rows when all are already unique" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'a')"
      db.exec "INSERT INTO t VALUES (2, 'b')"
      db.exec "INSERT INTO t VALUES (3, 'c')"

      rows = db.query_all("SELECT DISTINCT v FROM t", as: String)
      rows.sort.should eq ["a", "b", "c"]
    end
  end

  it "deduplicates multi-column projections" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'x', 'y')"
      db.exec "INSERT INTO t VALUES (2, 'x', 'y')"
      db.exec "INSERT INTO t VALUES (3, 'x', 'z')"

      rows = db.query_all("SELECT DISTINCT a, b FROM t", as: {String, String})
      rows.size.should eq 2
      rows.should contain({"x", "y"})
      rows.should contain({"x", "z"})
    end
  end

  it "works with WHERE clause" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, dept TEXT, name TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'eng', 'alice')"
      db.exec "INSERT INTO t VALUES (2, 'eng', 'bob')"
      db.exec "INSERT INTO t VALUES (3, 'eng', 'alice')"
      db.exec "INSERT INTO t VALUES (4, 'hr', 'carol')"

      rows = db.query_all("SELECT DISTINCT name FROM t WHERE dept = 'eng'", as: String)
      rows.sort.should eq ["alice", "bob"]
    end
  end

  it "works with ORDER BY" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'b')"
      db.exec "INSERT INTO t VALUES (2, 'a')"
      db.exec "INSERT INTO t VALUES (3, 'b')"
      db.exec "INSERT INTO t VALUES (4, 'c')"

      rows = db.query_all("SELECT DISTINCT v FROM t ORDER BY v ASC", as: String)
      rows.should eq ["a", "b", "c"]
    end
  end

  it "works with LIMIT" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'a')"
      db.exec "INSERT INTO t VALUES (2, 'b')"
      db.exec "INSERT INTO t VALUES (3, 'a')"
      db.exec "INSERT INTO t VALUES (4, 'c')"
      db.exec "INSERT INTO t VALUES (5, 'b')"

      rows = db.query_all("SELECT DISTINCT v FROM t ORDER BY v ASC LIMIT 2", as: String)
      rows.should eq ["a", "b"]
    end
  end

  it "handles NULL values — two NULLs count as one distinct value" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "INSERT INTO t VALUES (1, NULL)"
      db.exec "INSERT INTO t VALUES (2, NULL)"
      db.exec "INSERT INTO t VALUES (3, 'x')"

      rows = db.query_all("SELECT DISTINCT v FROM t", as: String?)
      rows.size.should eq 2
      rows.should contain(nil)
      rows.should contain("x")
    end
  end

  it "is equivalent to SELECT without DISTINCT when all rows are unique" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
      5.times { |i| db.exec "INSERT INTO t VALUES (?, ?)", i + 1, i + 1 }

      plain = db.query_all("SELECT v FROM t ORDER BY v", as: Int64)
      distinct = db.query_all("SELECT DISTINCT v FROM t ORDER BY v", as: Int64)
      distinct.should eq plain
    end
  end
end
