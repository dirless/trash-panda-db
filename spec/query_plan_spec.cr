require "./spec_helper"

describe "PK point lookups" do
  it "SELECT by PK avoids full scan" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      1000.times { |i| db.exec "INSERT INTO t (id, v) VALUES (?, ?)", i + 1, "val#{i + 1}" }
      row = db.query_one("SELECT v FROM t WHERE id = ?", 500, as: String)
      row.should eq "val500"
    end
  end

  it "UPDATE by PK" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 'old')"
      db.exec "UPDATE t SET v = 'new' WHERE id = 1"
      db.scalar("SELECT v FROM t WHERE id = 1").should eq "new"
    end
  end

  it "DELETE by PK" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 'a')"
      db.exec "INSERT INTO t (id, v) VALUES (2, 'b')"
      db.exec "DELETE FROM t WHERE id = 1"
      db.scalar("SELECT COUNT(*) FROM t").should eq 1_i64
      db.scalar("SELECT v FROM t").should eq "b"
    end
  end

  it "PK lookup returns empty when key not found" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 'a')"
      result = [] of String
      db.query("SELECT v FROM t WHERE id = ?", 99) { |rs| rs.each { result << rs.read(String) } }
      result.should be_empty
    end
  end
end

describe "Secondary indexes" do
  it "CREATE INDEX and use for equality lookup" do
    with_mem_db do |db|
      db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, name TEXT)"
      db.exec "INSERT INTO users (id, email, name) VALUES (1, 'alice@x.com', 'Alice')"
      db.exec "INSERT INTO users (id, email, name) VALUES (2, 'bob@x.com', 'Bob')"
      db.exec "INSERT INTO users (id, email, name) VALUES (3, 'carol@x.com', 'Carol')"
      db.exec "CREATE INDEX idx_email ON users(email)"
      name = db.query_one("SELECT name FROM users WHERE email = ?", "bob@x.com", as: String)
      name.should eq "Bob"
    end
  end

  it "index populated from existing rows at CREATE INDEX time" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
      10.times { |i| db.exec "INSERT INTO t (id, v) VALUES (?, ?)", i + 1, (i + 1) * 10 }
      db.exec "CREATE INDEX idx_v ON t(v)"
      count = db.scalar("SELECT COUNT(*) FROM t WHERE v = ?", 50_i64).as(Int64)
      count.should eq 1_i64
    end
  end

  it "INSERT maintains index" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "CREATE INDEX idx_v ON t(v)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 'hello')"
      db.exec "INSERT INTO t (id, v) VALUES (2, 'world')"
      name = db.query_one("SELECT id FROM t WHERE v = ?", "world", as: Int64)
      name.should eq 2_i64
    end
  end

  it "UPDATE maintains index" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "CREATE INDEX idx_v ON t(v)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 'old')"
      db.exec "UPDATE t SET v = 'new' WHERE id = 1"
      old_result = [] of Int64
      db.query("SELECT id FROM t WHERE v = ?", "old") { |rs| rs.each { old_result << rs.read(Int64) } }
      old_result.should be_empty
      db.query_one("SELECT id FROM t WHERE v = ?", "new", as: Int64).should eq 1_i64
    end
  end

  it "DELETE maintains index" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "CREATE INDEX idx_v ON t(v)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 'hello')"
      db.exec "DELETE FROM t WHERE id = 1"
      result = [] of String
      db.query("SELECT v FROM t WHERE v = ?", "hello") { |rs| rs.each { result << rs.read(String) } }
      result.should be_empty
    end
  end

  it "DROP INDEX removes index" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "CREATE INDEX idx_v ON t(v)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 'hello')"
      db.exec "DROP INDEX idx_v"
      db.scalar("SELECT COUNT(*) FROM t WHERE v = ?", "hello").should eq 1_i64
    end
  end

  it "DROP TABLE drops its indexes" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "CREATE INDEX idx_v ON t(v)"
      db.exec "DROP TABLE t"
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "CREATE INDEX idx_v ON t(v)"
    end
  end

  it "CREATE INDEX IF NOT EXISTS is idempotent" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "CREATE INDEX idx_v ON t(v)"
      db.exec "CREATE INDEX IF NOT EXISTS idx_v ON t(v)"
    end
  end
end

describe "VACUUM" do
  it "VACUUM runs without error and preserves data" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      10.times { |i| db.exec "INSERT INTO t (id, v) VALUES (?, ?)", i + 1, "v#{i + 1}" }
      db.exec "DELETE FROM t WHERE id <= 5"
      db.exec "VACUUM"
      db.scalar("SELECT COUNT(*) FROM t").should eq 5_i64
      db.scalar("SELECT v FROM t WHERE id = 10").should eq "v10"
    end
  end

  it "VACUUM with indexes preserves data" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "CREATE INDEX idx_v ON t(v)"
      5.times { |i| db.exec "INSERT INTO t (id, v) VALUES (?, ?)", i + 1, "val#{i + 1}" }
      db.exec "VACUUM"
      db.query_one("SELECT v FROM t WHERE v = ?", "val3", as: String).should eq "val3"
    end
  end
end
