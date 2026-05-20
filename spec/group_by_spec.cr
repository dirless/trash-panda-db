require "./spec_helper"

describe "GROUP BY / HAVING" do
  describe "basic GROUP BY" do
    it "groups rows and applies aggregate" do
      with_mem_db do |db|
        db.exec "CREATE TABLE orders (id INTEGER PRIMARY KEY, category TEXT, amount INTEGER)"
        db.exec "INSERT INTO orders (id, category, amount) VALUES (1, 'A', 100)"
        db.exec "INSERT INTO orders (id, category, amount) VALUES (2, 'A', 200)"
        db.exec "INSERT INTO orders (id, category, amount) VALUES (3, 'B', 50)"

        totals = Hash(String, Int64).new
        db.query("SELECT category, SUM(amount) FROM orders GROUP BY category") do |rs|
          rs.each { totals[rs.read(String)] = rs.read(Int64) }
        end
        totals["A"].should eq 300_i64
        totals["B"].should eq 50_i64
      end
    end

    it "COUNT(*) per group" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, g TEXT)"
        db.exec "INSERT INTO t (id, g) VALUES (1, 'x')"
        db.exec "INSERT INTO t (id, g) VALUES (2, 'x')"
        db.exec "INSERT INTO t (id, g) VALUES (3, 'y')"

        counts = Hash(String, Int64).new
        db.query("SELECT g, COUNT(*) FROM t GROUP BY g") do |rs|
          rs.each { counts[rs.read(String)] = rs.read(Int64) }
        end
        counts["x"].should eq 2_i64
        counts["y"].should eq 1_i64
      end
    end

    it "MAX and MIN per group" do
      with_mem_db do |db|
        db.exec "CREATE TABLE scores (id INTEGER PRIMARY KEY, player TEXT, score INTEGER)"
        db.exec "INSERT INTO scores (id, player, score) VALUES (1, 'Alice', 80)"
        db.exec "INSERT INTO scores (id, player, score) VALUES (2, 'Alice', 95)"
        db.exec "INSERT INTO scores (id, player, score) VALUES (3, 'Bob', 70)"
        db.exec "INSERT INTO scores (id, player, score) VALUES (4, 'Bob', 90)"

        maxes = Hash(String, Int64).new
        db.query("SELECT player, MAX(score) FROM scores GROUP BY player") do |rs|
          rs.each { maxes[rs.read(String)] = rs.read(Int64) }
        end
        maxes["Alice"].should eq 95_i64
        maxes["Bob"].should eq 90_i64

        mins = Hash(String, Int64).new
        db.query("SELECT player, MIN(score) FROM scores GROUP BY player") do |rs|
          rs.each { mins[rs.read(String)] = rs.read(Int64) }
        end
        mins["Alice"].should eq 80_i64
        mins["Bob"].should eq 70_i64
      end
    end

    it "AVG per group" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, g TEXT, v INTEGER)"
        db.exec "INSERT INTO t (id, g, v) VALUES (1, 'a', 10)"
        db.exec "INSERT INTO t (id, g, v) VALUES (2, 'a', 20)"
        db.exec "INSERT INTO t (id, g, v) VALUES (3, 'b', 30)"

        avgs = Hash(String, Float64).new
        db.query("SELECT g, AVG(v) FROM t GROUP BY g") do |rs|
          rs.each { avgs[rs.read(String)] = rs.read(Float64) }
        end
        avgs["a"].should eq 15.0
        avgs["b"].should eq 30.0
      end
    end

    it "GROUP BY single table produces correct row count" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, cat TEXT)"
        5.times { |i| db.exec "INSERT INTO t (id, cat) VALUES (?, ?)", i + 1, (i % 2 == 0 ? "even" : "odd") }

        count = db.scalar("SELECT COUNT(*) FROM (SELECT cat, COUNT(*) FROM t GROUP BY cat) AS sub").as(Int64)
        count.should eq 2_i64
      end
    end
  end

  describe "HAVING" do
    it "HAVING filters groups by aggregate condition" do
      with_mem_db do |db|
        db.exec "CREATE TABLE orders (id INTEGER PRIMARY KEY, category TEXT, amount INTEGER)"
        db.exec "INSERT INTO orders (id, category, amount) VALUES (1, 'A', 100)"
        db.exec "INSERT INTO orders (id, category, amount) VALUES (2, 'A', 200)"
        db.exec "INSERT INTO orders (id, category, amount) VALUES (3, 'B', 50)"
        db.exec "INSERT INTO orders (id, category, amount) VALUES (4, 'C', 10)"
        db.exec "INSERT INTO orders (id, category, amount) VALUES (5, 'C', 20)"

        cats = [] of String
        db.query("SELECT category FROM orders GROUP BY category HAVING SUM(amount) > 100") do |rs|
          rs.each { cats << rs.read(String) }
        end
        cats.sort.should eq ["A"]
      end
    end

    it "HAVING COUNT(*) >= 2" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, g TEXT)"
        db.exec "INSERT INTO t (id, g) VALUES (1, 'x')"
        db.exec "INSERT INTO t (id, g) VALUES (2, 'x')"
        db.exec "INSERT INTO t (id, g) VALUES (3, 'y')"

        count = db.scalar("SELECT COUNT(*) FROM (SELECT g FROM t GROUP BY g HAVING COUNT(*) >= 2) AS s").as(Int64)
        count.should eq 1_i64
      end
    end
  end

  describe "GROUP BY with WHERE" do
    it "WHERE filters before GROUP BY" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, g TEXT, v INTEGER)"
        db.exec "INSERT INTO t (id, g, v) VALUES (1, 'a', 5)"
        db.exec "INSERT INTO t (id, g, v) VALUES (2, 'a', 15)"
        db.exec "INSERT INTO t (id, g, v) VALUES (3, 'b', 5)"
        db.exec "INSERT INTO t (id, g, v) VALUES (4, 'b', 25)"

        totals = Hash(String, Int64).new
        db.query("SELECT g, SUM(v) FROM t WHERE v > 10 GROUP BY g") do |rs|
          rs.each { totals[rs.read(String)] = rs.read(Int64) }
        end
        totals["a"]?.should eq 15_i64
        totals["b"]?.should eq 25_i64
        totals.has_key?("a") || totals.has_key?("b") # at least one group
        totals.size.should eq 2
      end
    end
  end

  describe "GROUP BY on JOIN" do
    it "GROUP BY on joined rows" do
      with_mem_db do |db|
        db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER, amount INTEGER)"
        db.exec "INSERT INTO users (id, name) VALUES (1, 'Alice')"
        db.exec "INSERT INTO users (id, name) VALUES (2, 'Bob')"
        db.exec "INSERT INTO orders (id, user_id, amount) VALUES (1, 1, 100)"
        db.exec "INSERT INTO orders (id, user_id, amount) VALUES (2, 1, 50)"
        db.exec "INSERT INTO orders (id, user_id, amount) VALUES (3, 2, 200)"

        totals = Hash(String, Int64).new
        db.query("SELECT users.name, SUM(orders.amount) FROM users JOIN orders ON users.id = orders.user_id GROUP BY users.name") do |rs|
          rs.each { totals[rs.read(String)] = rs.read(Int64) }
        end
        totals["Alice"].should eq 150_i64
        totals["Bob"].should eq 200_i64
      end
    end
  end
end
