require "./spec_helper"

ALTER_DB = "./test_alter.tpdb"

private def cleanup_alter_db
  File.delete(ALTER_DB) rescue nil
  File.delete("#{ALTER_DB}-wal") rescue nil
end

private def open_alter_db(&block : DB::Database ->)
  DB.open "trashpanda:#{ALTER_DB}", &block
end

describe "ALTER TABLE" do
  describe "ADD COLUMN" do
    it "adds a nullable column with no default" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "INSERT INTO t (name) VALUES ('Alice')"
        db.exec "ALTER TABLE t ADD COLUMN age INTEGER"
        cols = db.query_all "SELECT name, age FROM t", as: {String, Int32?}
        cols.should eq([{"Alice", nil}])
      end
    end

    it "adds a column with a DEFAULT value" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "INSERT INTO t (name) VALUES ('Alice')"
        db.exec "INSERT INTO t (name) VALUES ('Bob')"
        db.exec "ALTER TABLE t ADD COLUMN score INTEGER DEFAULT 0"
        scores = db.query_all "SELECT score FROM t ORDER BY name", as: Int32
        scores.should eq([0, 0])
        db.exec "INSERT INTO t (name, score) VALUES ('Carol', 99)"
        all = db.query_all "SELECT name, score FROM t ORDER BY name", as: {String, Int32?}
        all.should eq([{"Alice", 0}, {"Bob", 0}, {"Carol", 99}])
      end
    end

    it "adds a TEXT column with string default" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
        db.exec "INSERT INTO t (id) VALUES (1)"
        db.exec "ALTER TABLE t ADD COLUMN status TEXT DEFAULT 'active'"
        val = db.query_one "SELECT status FROM t WHERE id = 1", as: String
        val.should eq("active")
      end
    end

    it "allows ADD COLUMN COLUMN keyword" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
        db.exec "ALTER TABLE t ADD COLUMN extra TEXT"
        db.exec "INSERT INTO t (id, extra) VALUES (1, 'x')"
        db.query_one("SELECT extra FROM t", as: String).should eq("x")
      end
    end

    it "rejects duplicate column name" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
        expect_raises(DB::Error, /already exists/) do
          db.exec "ALTER TABLE t ADD COLUMN name TEXT"
        end
      end
    end

    it "rejects NOT NULL without default when rows exist" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
        db.exec "INSERT INTO t (id) VALUES (1)"
        expect_raises(DB::Error, /null values/) do
          db.exec "ALTER TABLE t ADD COLUMN val TEXT NOT NULL"
        end
      end
    end

    it "allows NOT NULL without default when table is empty" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
        db.exec "ALTER TABLE t ADD COLUMN val TEXT NOT NULL"
        db.exec "INSERT INTO t (id, val) VALUES (1, 'ok')"
        db.query_one("SELECT val FROM t", as: String).should eq("ok")
      end
    end

    it "persists the new column across reconnects" do
      cleanup_alter_db
      open_alter_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "INSERT INTO t (name) VALUES ('Alice')"
        db.exec "ALTER TABLE t ADD COLUMN score INTEGER DEFAULT 42"
      end
      open_alter_db do |db|
        val = db.query_one "SELECT score FROM t", as: Int32
        val.should eq(42)
      end
      cleanup_alter_db
    end
  end

  describe "DROP COLUMN" do
    it "removes a column and its data" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, extra TEXT)"
        db.exec "INSERT INTO t (name, extra) VALUES ('Alice', 'foo')"
        db.exec "ALTER TABLE t DROP COLUMN extra"
        names = db.query_all "SELECT name FROM t", as: String
        names.should eq(["Alice"])
        expect_raises(DB::Error, /no such column/) do
          db.query_one "SELECT extra FROM t", as: String
        end
      end
    end

    it "allows DROP COLUMN COLUMN keyword" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT, y TEXT)"
        db.exec "INSERT INTO t (x, y) VALUES ('a', 'b')"
        db.exec "ALTER TABLE t DROP COLUMN y"
        db.query_one("SELECT x FROM t", as: String).should eq("a")
      end
    end

    it "rejects dropping the primary key column" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
        expect_raises(DB::Error, /PRIMARY KEY/) do
          db.exec "ALTER TABLE t DROP COLUMN id"
        end
      end
    end

    it "rejects dropping a non-existent column" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
        expect_raises(DB::Error, /no such column/) do
          db.exec "ALTER TABLE t DROP COLUMN ghost"
        end
      end
    end

    it "drops associated index" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, email TEXT)"
        db.exec "CREATE INDEX idx_email ON t (email)"
        db.exec "INSERT INTO t (email) VALUES ('a@b.com')"
        db.exec "ALTER TABLE t DROP COLUMN email"
        # Index should be gone — re-creating it should succeed
        db.exec "CREATE TABLE t2 (id INTEGER PRIMARY KEY, email TEXT)"
        db.exec "CREATE INDEX idx_email ON t2 (email)"
      end
    end

    it "keeps remaining columns correct after drop of middle column" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b INTEGER, c TEXT)"
        db.exec "INSERT INTO t (a, b, c) VALUES ('x', 99, 'z')"
        db.exec "ALTER TABLE t DROP COLUMN b"
        row = db.query_one "SELECT a, c FROM t", as: {String, String}
        row.should eq({"x", "z"})
      end
    end

    it "persists column drop across reconnects" do
      cleanup_alter_db
      open_alter_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, tmp TEXT)"
        db.exec "INSERT INTO t (name, tmp) VALUES ('Alice', 'discard')"
        db.exec "ALTER TABLE t DROP COLUMN tmp"
      end
      open_alter_db do |db|
        expect_raises(DB::Error, /no such column/) do
          db.query_one "SELECT tmp FROM t", as: String
        end
        db.query_one("SELECT name FROM t", as: String).should eq("Alice")
      end
      cleanup_alter_db
    end
  end

  describe "RENAME COLUMN" do
    it "renames a column" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, fname TEXT)"
        db.exec "INSERT INTO t (fname) VALUES ('Alice')"
        db.exec "ALTER TABLE t RENAME COLUMN fname TO first_name"
        val = db.query_one "SELECT first_name FROM t", as: String
        val.should eq("Alice")
        expect_raises(DB::Error, /no such column/) do
          db.query_one "SELECT fname FROM t", as: String
        end
      end
    end

    it "allows RENAME COLUMN COLUMN keyword" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, old_name TEXT)"
        db.exec "ALTER TABLE t RENAME COLUMN old_name TO new_name"
        db.exec "INSERT INTO t (new_name) VALUES ('ok')"
        db.query_one("SELECT new_name FROM t", as: String).should eq("ok")
      end
    end

    it "rejects renaming to an existing column name" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b TEXT)"
        expect_raises(DB::Error, /already exists/) do
          db.exec "ALTER TABLE t RENAME COLUMN a TO b"
        end
      end
    end

    it "rejects renaming a non-existent column" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
        expect_raises(DB::Error, /no such column/) do
          db.exec "ALTER TABLE t RENAME COLUMN ghost TO real"
        end
      end
    end

    it "updates index metadata when renaming indexed column" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, email TEXT)"
        db.exec "CREATE INDEX idx_email ON t (email)"
        db.exec "INSERT INTO t (email) VALUES ('a@b.com')"
        db.exec "ALTER TABLE t RENAME COLUMN email TO mail"
        # Index still finds rows via the renamed column
        val = db.query_one "SELECT mail FROM t WHERE mail = 'a@b.com'", as: String
        val.should eq("a@b.com")
      end
    end

    it "persists rename across reconnects" do
      cleanup_alter_db
      open_alter_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, old_col TEXT)"
        db.exec "INSERT INTO t (old_col) VALUES ('data')"
        db.exec "ALTER TABLE t RENAME COLUMN old_col TO new_col"
      end
      open_alter_db do |db|
        db.query_one("SELECT new_col FROM t", as: String).should eq("data")
      end
      cleanup_alter_db
    end
  end

  describe "RENAME TO" do
    it "renames a table" do
      with_mem_db do |db|
        db.exec "CREATE TABLE old_name (id INTEGER PRIMARY KEY, val TEXT)"
        db.exec "INSERT INTO old_name (val) VALUES ('row1')"
        db.exec "ALTER TABLE old_name RENAME TO new_name"
        val = db.query_one "SELECT val FROM new_name", as: String
        val.should eq("row1")
        expect_raises(DB::Error, /no such table/) do
          db.query_one "SELECT val FROM old_name", as: String
        end
      end
    end

    it "rejects renaming to an existing table name" do
      with_mem_db do |db|
        db.exec "CREATE TABLE a (id INTEGER PRIMARY KEY)"
        db.exec "CREATE TABLE b (id INTEGER PRIMARY KEY)"
        expect_raises(DB::Error, /already exists/) do
          db.exec "ALTER TABLE a RENAME TO b"
        end
      end
    end

    it "rejects renaming a non-existent table" do
      with_mem_db do |db|
        expect_raises(DB::Error, /no such table/) do
          db.exec "ALTER TABLE ghost RENAME TO real"
        end
      end
    end

    it "preserves indexes after rename" do
      with_mem_db do |db|
        db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)"
        db.exec "CREATE INDEX idx_email ON users (email)"
        db.exec "INSERT INTO users (email) VALUES ('a@b.com')"
        db.exec "ALTER TABLE users RENAME TO accounts"
        val = db.query_one "SELECT email FROM accounts WHERE email = 'a@b.com'", as: String
        val.should eq("a@b.com")
      end
    end

    it "persists rename across reconnects" do
      cleanup_alter_db
      open_alter_db do |db|
        db.exec "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "INSERT INTO items (name) VALUES ('thing')"
        db.exec "ALTER TABLE items RENAME TO products"
      end
      open_alter_db do |db|
        db.query_one("SELECT name FROM products", as: String).should eq("thing")
      end
      cleanup_alter_db
    end
  end

  describe "round-trip migration" do
    it "create → insert → alter → query → integrity" do
      with_mem_db do |db|
        db.exec "CREATE TABLE employees (id INTEGER PRIMARY KEY, name TEXT NOT NULL, salary INTEGER)"
        db.exec "INSERT INTO employees (name, salary) VALUES ('Alice', 50000)"
        db.exec "INSERT INTO employees (name, salary) VALUES ('Bob', 60000)"

        # Add a column with default
        db.exec "ALTER TABLE employees ADD COLUMN department TEXT DEFAULT 'engineering'"
        depts = db.query_all "SELECT department FROM employees ORDER BY name", as: String
        depts.should eq(["engineering", "engineering"])

        # Rename a column
        db.exec "ALTER TABLE employees RENAME COLUMN salary TO compensation"
        vals = db.query_all "SELECT name, compensation FROM employees ORDER BY name", as: {String, Int32}
        vals.should eq([{"Alice", 50000}, {"Bob", 60000}])

        # Drop a column
        db.exec "ALTER TABLE employees DROP COLUMN department"
        expect_raises(DB::Error, /no such column/) do
          db.query_one "SELECT department FROM employees", as: String
        end

        # Rename table
        db.exec "ALTER TABLE employees RENAME TO staff"
        count = db.query_one "SELECT COUNT(*) FROM staff", as: Int64
        count.should eq(2_i64)

        # New inserts into renamed table work
        db.exec "INSERT INTO staff (name, compensation) VALUES ('Carol', 70000)"
        count2 = db.query_one "SELECT COUNT(*) FROM staff", as: Int64
        count2.should eq(3_i64)
      end
    end
  end
end
