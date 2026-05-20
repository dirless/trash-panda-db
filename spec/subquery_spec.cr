require "./spec_helper"

describe "Sub-select in FROM" do
  it "SELECT * from a simple subquery" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO t (id, name) VALUES (1, 'Alice')"
      db.exec "INSERT INTO t (id, name) VALUES (2, 'Bob')"

      names = [] of String
      db.query("SELECT sub.name FROM (SELECT id, name FROM t) AS sub") do |rs|
        rs.each { names << rs.read(String) }
      end
      names.sort.should eq ["Alice", "Bob"]
    end
  end

  it "WHERE on subquery result" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 10)"
      db.exec "INSERT INTO t (id, v) VALUES (2, 20)"
      db.exec "INSERT INTO t (id, v) VALUES (3, 30)"

      count = db.scalar("SELECT COUNT(*) FROM (SELECT id, v FROM t) AS sub WHERE sub.v > 15").as(Int64)
      count.should eq 2_i64
    end
  end

  it "aggregate on subquery result" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 5)"
      db.exec "INSERT INTO t (id, v) VALUES (2, 15)"
      db.exec "INSERT INTO t (id, v) VALUES (3, 25)"

      total = db.scalar("SELECT SUM(sub.v) FROM (SELECT v FROM t WHERE v > 10) AS sub").as(Int64)
      total.should eq 40_i64
    end
  end

  it "subquery can itself have WHERE" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, cat TEXT, v INTEGER)"
      db.exec "INSERT INTO t (id, cat, v) VALUES (1, 'a', 10)"
      db.exec "INSERT INTO t (id, cat, v) VALUES (2, 'a', 20)"
      db.exec "INSERT INTO t (id, cat, v) VALUES (3, 'b', 30)"

      count = db.scalar("SELECT COUNT(*) FROM (SELECT id, v FROM t WHERE cat = 'a') AS sub").as(Int64)
      count.should eq 2_i64
    end
  end

  it "ORDER BY on subquery result" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 30)"
      db.exec "INSERT INTO t (id, v) VALUES (2, 10)"
      db.exec "INSERT INTO t (id, v) VALUES (3, 20)"

      vals = [] of Int64
      db.query("SELECT sub.v FROM (SELECT v FROM t) AS sub ORDER BY sub.v ASC") do |rs|
        rs.each { vals << rs.read(Int64) }
      end
      vals.should eq [10_i64, 20_i64, 30_i64]
    end
  end

  it "GROUP BY on subquery result" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, cat TEXT, v INTEGER)"
      db.exec "INSERT INTO t (id, cat, v) VALUES (1, 'a', 10)"
      db.exec "INSERT INTO t (id, cat, v) VALUES (2, 'a', 20)"
      db.exec "INSERT INTO t (id, cat, v) VALUES (3, 'b', 5)"

      totals = Hash(String, Int64).new
      db.query("SELECT sub.cat, SUM(sub.v) FROM (SELECT cat, v FROM t) AS sub GROUP BY sub.cat") do |rs|
        rs.each { totals[rs.read(String)] = rs.read(Int64) }
      end
      totals["a"].should eq 30_i64
      totals["b"].should eq 5_i64
    end
  end

  it "unqualified column reference in outer query" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO t (id, name) VALUES (1, 'Alice')"

      name = db.query_one("SELECT name FROM (SELECT id, name FROM t) AS sub", as: String)
      name.should eq "Alice"
    end
  end
end
