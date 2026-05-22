require "./spec_helper"

describe "SQL completeness (Item 18)" do
  describe "IN (subquery)" do
    it "selects rows where column IN (subquery)" do
      with_mem_db do |db|
        db.exec "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, active INTEGER)"
        db.exec "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, amount INTEGER)"
        db.exec "INSERT INTO customers (name, active) VALUES ('Alice', 1)"
        db.exec "INSERT INTO customers (name, active) VALUES ('Bob', 0)"
        db.exec "INSERT INTO customers (name, active) VALUES ('Carol', 1)"
        db.exec "INSERT INTO orders (customer_id, amount) VALUES (1, 100)"
        db.exec "INSERT INTO orders (customer_id, amount) VALUES (3, 200)"

        names = db.query_all(
          "SELECT name FROM customers WHERE id IN (SELECT customer_id FROM orders)",
          as: String
        ).sort
        names.should eq(["Alice", "Carol"])
      end
    end

    it "supports NOT IN (subquery)" do
      with_mem_db do |db|
        db.exec "CREATE TABLE all_ids (id INTEGER PRIMARY KEY)"
        db.exec "CREATE TABLE used_ids (id INTEGER PRIMARY KEY)"
        db.exec "INSERT INTO all_ids (id) VALUES (1)"
        db.exec "INSERT INTO all_ids (id) VALUES (2)"
        db.exec "INSERT INTO all_ids (id) VALUES (3)"
        db.exec "INSERT INTO used_ids (id) VALUES (2)"

        ids = db.query_all(
          "SELECT id FROM all_ids WHERE id NOT IN (SELECT id FROM used_ids)",
          as: Int64
        ).sort
        ids.should eq([1_i64, 3_i64])
      end
    end

    it "supports IN (literal list)" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)"
        db.exec "INSERT INTO t (val) VALUES ('a')"
        db.exec "INSERT INTO t (val) VALUES ('b')"
        db.exec "INSERT INTO t (val) VALUES ('c')"

        vals = db.query_all "SELECT val FROM t WHERE val IN ('a', 'c')", as: String
        vals.sort.should eq(["a", "c"])
      end
    end

    it "supports NOT IN (literal list)" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)"
        [1, 2, 3, 4, 5].each { |i| db.exec "INSERT INTO t (n) VALUES (#{i})" }

        result = db.query_all "SELECT n FROM t WHERE n NOT IN (2, 4)", as: Int32
        result.sort.should eq([1, 3, 5])
      end
    end

    it "IN with subquery that returns empty set matches nothing" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
        db.exec "CREATE TABLE empty (id INTEGER PRIMARY KEY)"
        db.exec "INSERT INTO t (id) VALUES (1)"
        db.exec "INSERT INTO t (id) VALUES (2)"

        ids = db.query_all "SELECT id FROM t WHERE id IN (SELECT id FROM empty)", as: Int64
        ids.should be_empty
      end
    end

    it "NOT IN with empty subquery matches all rows" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
        db.exec "CREATE TABLE empty (id INTEGER PRIMARY KEY)"
        db.exec "INSERT INTO t (id) VALUES (1)"
        db.exec "INSERT INTO t (id) VALUES (2)"

        ids = db.query_all "SELECT id FROM t WHERE id NOT IN (SELECT id FROM empty)", as: Int64
        ids.sort.should eq([1_i64, 2_i64])
      end
    end

    it "works in WHERE of a JOIN" do
      with_mem_db do |db|
        db.exec "CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, category_id INTEGER)"
        db.exec "CREATE TABLE featured_categories (id INTEGER PRIMARY KEY)"
        db.exec "INSERT INTO products (name, category_id) VALUES ('Foo', 1)"
        db.exec "INSERT INTO products (name, category_id) VALUES ('Bar', 2)"
        db.exec "INSERT INTO products (name, category_id) VALUES ('Baz', 1)"
        db.exec "INSERT INTO featured_categories (id) VALUES (1)"

        names = db.query_all(
          "SELECT name FROM products WHERE category_id IN (SELECT id FROM featured_categories)",
          as: String
        ).sort
        names.should eq(["Baz", "Foo"])
      end
    end
  end

  describe "UPDATE … FROM" do
    it "updates rows using a join with another table" do
      with_mem_db do |db|
        db.exec "CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT)"
        db.exec "CREATE TABLE shipments (order_id INTEGER, dispatched INTEGER)"
        db.exec "INSERT INTO orders (status) VALUES ('pending')"
        db.exec "INSERT INTO orders (status) VALUES ('pending')"
        db.exec "INSERT INTO orders (status) VALUES ('pending')"
        db.exec "INSERT INTO shipments (order_id, dispatched) VALUES (1, 1)"
        db.exec "INSERT INTO shipments (order_id, dispatched) VALUES (3, 1)"

        db.exec "UPDATE orders SET status = 'shipped' FROM shipments WHERE orders.id = shipments.order_id AND shipments.dispatched = 1"

        rows = db.query_all "SELECT id, status FROM orders ORDER BY id", as: {Int64, String}
        rows.should eq([{1_i64, "shipped"}, {2_i64, "pending"}, {3_i64, "shipped"}])
      end
    end

    it "plain UPDATE still works (no regression)" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        db.exec "INSERT INTO t (v) VALUES (1)"
        db.exec "INSERT INTO t (v) VALUES (2)"
        db.exec "UPDATE t SET v = 99 WHERE id = 1"
        vals = db.query_all "SELECT v FROM t ORDER BY id", as: Int32
        vals.should eq([99, 2])
      end
    end
  end

  describe "DELETE … USING" do
    it "deletes rows matched by a join" do
      with_mem_db do |db|
        db.exec "CREATE TABLE sessions (id INTEGER PRIMARY KEY, user_id INTEGER)"
        db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, banned INTEGER)"
        db.exec "INSERT INTO sessions (user_id) VALUES (1)"
        db.exec "INSERT INTO sessions (user_id) VALUES (2)"
        db.exec "INSERT INTO sessions (user_id) VALUES (3)"
        db.exec "INSERT INTO users (id, banned) VALUES (1, 0)"
        db.exec "INSERT INTO users (id, banned) VALUES (2, 1)"
        db.exec "INSERT INTO users (id, banned) VALUES (3, 0)"

        db.exec "DELETE FROM sessions USING users WHERE sessions.user_id = users.id AND users.banned = 1"

        remaining = db.query_all "SELECT user_id FROM sessions ORDER BY user_id", as: Int64
        remaining.should eq([1_i64, 3_i64])
      end
    end

    it "plain DELETE still works (no regression)" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        db.exec "INSERT INTO t (v) VALUES (1)"
        db.exec "INSERT INTO t (v) VALUES (2)"
        db.exec "DELETE FROM t WHERE id = 1"
        vals = db.query_all "SELECT v FROM t", as: Int32
        vals.should eq([2])
      end
    end
  end

  describe "RETURNING" do
    describe "INSERT … RETURNING" do
      it "returns inserted row columns" do
        with_mem_db do |db|
          db.exec "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)"
          rows = db.query_all "INSERT INTO items (name) VALUES ('foo') RETURNING id, name", as: {Int64, String}
          rows.should eq([{1_i64, "foo"}])
        end
      end

      it "returns * from inserted row" do
        with_mem_db do |db|
          db.exec "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, score INTEGER)"
          db.exec "INSERT INTO items (name, score) VALUES ('bar', 42)"
          rows = db.query_all "INSERT INTO items (name, score) VALUES ('baz', 99) RETURNING *", as: {Int64, String, Int32}
          rows.should eq([{2_i64, "baz", 99}])
        end
      end

      it "returns multiple inserted rows" do
        with_mem_db do |db|
          db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
          rows = db.query_all(
            "INSERT INTO t (v) VALUES ('a'), ('b'), ('c') RETURNING id, v",
            as: {Int64, String}
          )
          rows.should eq([{1_i64, "a"}, {2_i64, "b"}, {3_i64, "c"}])
        end
      end

      it "returns id only" do
        with_mem_db do |db|
          db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
          id = db.query_one "INSERT INTO t (name) VALUES ('hello') RETURNING id", as: Int64
          id.should eq(1_i64)
        end
      end
    end

    describe "UPDATE … RETURNING" do
      it "returns updated rows" do
        with_mem_db do |db|
          db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
          db.exec "INSERT INTO t (v) VALUES (1)"
          db.exec "INSERT INTO t (v) VALUES (2)"
          db.exec "INSERT INTO t (v) VALUES (3)"

          rows = db.query_all "UPDATE t SET v = 99 WHERE id <= 2 RETURNING id, v", as: {Int64, Int32}
          rows.sort_by(&.first).should eq([{1_i64, 99}, {2_i64, 99}])
        end
      end

      it "returns * from updated row" do
        with_mem_db do |db|
          db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
          db.exec "INSERT INTO t (name) VALUES ('old')"
          rows = db.query_all "UPDATE t SET name = 'new' WHERE id = 1 RETURNING *", as: {Int64, String}
          rows.should eq([{1_i64, "new"}])
        end
      end
    end

    describe "DELETE … RETURNING" do
      it "returns deleted rows" do
        with_mem_db do |db|
          db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
          db.exec "INSERT INTO t (v) VALUES ('keep')"
          db.exec "INSERT INTO t (v) VALUES ('delete_me')"
          db.exec "INSERT INTO t (v) VALUES ('also_keep')"

          rows = db.query_all "DELETE FROM t WHERE v = 'delete_me' RETURNING id, v", as: {Int64, String}
          rows.should eq([{2_i64, "delete_me"}])
          count = db.query_one "SELECT COUNT(*) FROM t", as: Int64
          count.should eq(2_i64)
        end
      end

      it "returns * from deleted rows" do
        with_mem_db do |db|
          db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)"
          db.exec "INSERT INTO t (n) VALUES (1)"
          db.exec "INSERT INTO t (n) VALUES (2)"
          rows = db.query_all "DELETE FROM t RETURNING *", as: {Int64, Int32}
          rows.size.should eq(2)
          db.query_one("SELECT COUNT(*) FROM t", as: Int64).should eq(0_i64)
        end
      end
    end
  end

  describe "combined scenarios" do
    it "IN subquery + RETURNING together" do
      with_mem_db do |db|
        db.exec "CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, active INTEGER)"
        db.exec "CREATE TABLE to_deactivate (product_id INTEGER PRIMARY KEY)"
        db.exec "INSERT INTO products (name, active) VALUES ('A', 1)"
        db.exec "INSERT INTO products (name, active) VALUES ('B', 1)"
        db.exec "INSERT INTO products (name, active) VALUES ('C', 1)"
        db.exec "INSERT INTO to_deactivate (product_id) VALUES (2)"

        rows = db.query_all(
          "UPDATE products SET active = 0 WHERE id IN (SELECT product_id FROM to_deactivate) RETURNING id, name",
          as: {Int64, String}
        )
        rows.should eq([{2_i64, "B"}])
      end
    end
  end
end
