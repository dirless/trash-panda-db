require "./spec_helper"

describe "JOIN support" do
  describe "INNER JOIN" do
    it "basic INNER JOIN with ON condition" do
      with_mem_db do |db|
        db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER, amount INTEGER)"
        db.exec "INSERT INTO users (id, name) VALUES (1, 'Alice')"
        db.exec "INSERT INTO users (id, name) VALUES (2, 'Bob')"
        db.exec "INSERT INTO orders (id, user_id, amount) VALUES (1, 1, 100)"
        db.exec "INSERT INTO orders (id, user_id, amount) VALUES (2, 1, 200)"
        db.exec "INSERT INTO orders (id, user_id, amount) VALUES (3, 2, 50)"

        names = [] of String
        amounts = [] of Int64
        db.query("SELECT users.name, orders.amount FROM users JOIN orders ON users.id = orders.user_id") do |rs|
          rs.each { names << rs.read(String); amounts << rs.read(Int64) }
        end
        names.sort.should eq ["Alice", "Alice", "Bob"]
        amounts.sort.should eq [50_i64, 100_i64, 200_i64]
      end
    end

    it "INNER JOIN excludes non-matching rows" do
      with_mem_db do |db|
        db.exec "CREATE TABLE a (id INTEGER PRIMARY KEY, v TEXT)"
        db.exec "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER, w TEXT)"
        db.exec "INSERT INTO a (id, v) VALUES (1, 'x')"
        db.exec "INSERT INTO a (id, v) VALUES (2, 'y')"  # no matching b row
        db.exec "INSERT INTO b (id, a_id, w) VALUES (1, 1, 'z')"

        count = db.scalar("SELECT COUNT(*) FROM a INNER JOIN b ON a.id = b.a_id").as(Int64)
        count.should eq 1_i64
      end
    end

    it "JOIN with bare JOIN keyword (defaults to INNER)" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t1 (id INTEGER PRIMARY KEY, v TEXT)"
        db.exec "CREATE TABLE t2 (id INTEGER PRIMARY KEY, t1_id INTEGER)"
        db.exec "INSERT INTO t1 (id, v) VALUES (1, 'hello')"
        db.exec "INSERT INTO t2 (id, t1_id) VALUES (10, 1)"

        v = db.query_one("SELECT t1.v FROM t1 JOIN t2 ON t1.id = t2.t1_id", as: String)
        v.should eq "hello"
      end
    end
  end

  describe "LEFT JOIN" do
    it "LEFT JOIN includes unmatched left rows with NULL right columns" do
      with_mem_db do |db|
        db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER)"
        db.exec "INSERT INTO users (id, name) VALUES (1, 'Alice')"
        db.exec "INSERT INTO users (id, name) VALUES (2, 'Bob')"
        db.exec "INSERT INTO orders (id, user_id) VALUES (1, 1)"

        names = [] of String
        order_ids = [] of Int64?
        db.query("SELECT users.name, orders.id FROM users LEFT JOIN orders ON users.id = orders.user_id") do |rs|
          rs.each { names << rs.read(String); order_ids << rs.read(Int64?) }
        end
        names.sort.should eq ["Alice", "Bob"]
        order_ids.compact.should eq [1_i64]
        order_ids.any?(&.nil?).should be_true
      end
    end

    it "LEFT OUTER JOIN is synonym for LEFT JOIN" do
      with_mem_db do |db|
        db.exec "CREATE TABLE a (id INTEGER PRIMARY KEY)"
        db.exec "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER)"
        db.exec "INSERT INTO a (id) VALUES (1)"
        db.exec "INSERT INTO a (id) VALUES (2)"
        db.exec "INSERT INTO b (id, a_id) VALUES (1, 1)"

        count = db.scalar("SELECT COUNT(*) FROM a LEFT OUTER JOIN b ON a.id = b.a_id").as(Int64)
        count.should eq 2_i64
      end
    end
  end

  describe "table aliases" do
    it "supports table aliases in JOIN" do
      with_mem_db do |db|
        db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER, amount INTEGER)"
        db.exec "INSERT INTO users (id, name) VALUES (1, 'Alice')"
        db.exec "INSERT INTO orders (id, user_id, amount) VALUES (1, 1, 42)"

        amount = db.query_one("SELECT o.amount FROM users u JOIN orders o ON u.id = o.user_id", as: Int64)
        amount.should eq 42_i64
      end
    end

    it "supports alias in single-table SELECT" do
      with_mem_db do |db|
        db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "INSERT INTO users (id, name) VALUES (1, 'Alice')"

        name = db.query_one("SELECT u.name FROM users u WHERE u.id = 1", as: String)
        name.should eq "Alice"
      end
    end
  end

  describe "WHERE on joined rows" do
    it "WHERE filters joined result" do
      with_mem_db do |db|
        db.exec "CREATE TABLE p (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "CREATE TABLE o (id INTEGER PRIMARY KEY, p_id INTEGER, total INTEGER)"
        db.exec "INSERT INTO p (id, name) VALUES (1, 'Alice')"
        db.exec "INSERT INTO p (id, name) VALUES (2, 'Bob')"
        db.exec "INSERT INTO o (id, p_id, total) VALUES (1, 1, 100)"
        db.exec "INSERT INTO o (id, p_id, total) VALUES (2, 2, 10)"
        db.exec "INSERT INTO o (id, p_id, total) VALUES (3, 1, 500)"

        count = db.scalar("SELECT COUNT(*) FROM p JOIN o ON p.id = o.p_id WHERE o.total > 50").as(Int64)
        count.should eq 2_i64
      end
    end
  end

  describe "SELECT * in JOIN" do
    it "SELECT * returns columns from all tables" do
      with_mem_db do |db|
        db.exec "CREATE TABLE a (id INTEGER PRIMARY KEY, v TEXT)"
        db.exec "CREATE TABLE b (id INTEGER PRIMARY KEY, w TEXT)"
        db.exec "INSERT INTO a (id, v) VALUES (1, 'hello')"
        db.exec "INSERT INTO b (id, w) VALUES (1, 'world')"

        # SELECT * from a JOIN b should yield 4 columns: id, v, id, w
        count = 0
        db.query("SELECT * FROM a JOIN b ON a.id = b.id") do |rs|
          rs.each { count += 1; rs.read(Int64); rs.read(String); rs.read(Int64); rs.read(String) }
        end
        count.should eq 1
      end
    end
  end

  describe "aggregate on JOIN" do
    it "COUNT(*) on JOIN result" do
      with_mem_db do |db|
        db.exec "CREATE TABLE a (id INTEGER PRIMARY KEY)"
        db.exec "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER)"
        3.times { |i| db.exec "INSERT INTO a (id) VALUES (?)", i + 1 }
        db.exec "INSERT INTO b (id, a_id) VALUES (1, 1)"
        db.exec "INSERT INTO b (id, a_id) VALUES (2, 1)"
        db.exec "INSERT INTO b (id, a_id) VALUES (3, 2)"

        count = db.scalar("SELECT COUNT(*) FROM a JOIN b ON a.id = b.a_id").as(Int64)
        count.should eq 3_i64
      end
    end
  end

  describe "chained JOINs" do
    it "three-table JOIN" do
      with_mem_db do |db|
        db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER)"
        db.exec "CREATE TABLE items (id INTEGER PRIMARY KEY, order_id INTEGER, product TEXT)"
        db.exec "INSERT INTO users (id, name) VALUES (1, 'Alice')"
        db.exec "INSERT INTO orders (id, user_id) VALUES (10, 1)"
        db.exec "INSERT INTO items (id, order_id, product) VALUES (100, 10, 'Widget')"

        product = db.query_one(
          "SELECT items.product FROM users JOIN orders ON users.id = orders.user_id JOIN items ON orders.id = items.order_id",
          as: String
        )
        product.should eq "Widget"
      end
    end
  end
end
