require "./spec_helper"

describe "ResultSet typed read methods" do
  it "read(Int64) returns Int64 for integer column" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x INTEGER)"
      db.exec "INSERT INTO t VALUES (42)"
      val = db.query_one("SELECT x FROM t", as: Int64)
      val.should eq(42_i64)
    end
  end

  it "read(Int64?) returns nil for null integer column" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x INTEGER)"
      db.exec "INSERT INTO t VALUES (NULL)"
      val = db.query_one("SELECT x FROM t", as: Int64?)
      val.should be_nil
    end
  end

  it "read(Int64?) returns Int64 for non-null integer column" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x INTEGER)"
      db.exec "INSERT INTO t VALUES (99)"
      val = db.query_one("SELECT x FROM t", as: Int64?)
      val.should eq(99_i64)
    end
  end

  it "read(Float64) returns Float64 for real column" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x REAL)"
      db.exec "INSERT INTO t VALUES (3.14)"
      val = db.query_one("SELECT x FROM t", as: Float64)
      val.should be_close(3.14, 0.001)
    end
  end

  it "read(Float64?) returns nil for null real column" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x REAL)"
      db.exec "INSERT INTO t VALUES (NULL)"
      val = db.query_one("SELECT x FROM t", as: Float64?)
      val.should be_nil
    end
  end

  it "read(Float64) accepts Int64 column value (integer widening)" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x INTEGER)"
      db.exec "INSERT INTO t VALUES (10)"
      val = db.query_one("SELECT x FROM t", as: Float64)
      val.should eq(10.0)
    end
  end

  it "read(String) returns String for text column" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x TEXT)"
      db.exec "INSERT INTO t VALUES ('hello')"
      val = db.query_one("SELECT x FROM t", as: String)
      val.should eq("hello")
    end
  end

  it "read(String?) returns nil for null text column" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x TEXT)"
      db.exec "INSERT INTO t VALUES (NULL)"
      val = db.query_one("SELECT x FROM t", as: String?)
      val.should be_nil
    end
  end

  it "read(String?) raises ColumnTypeMismatchError for integer column value" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x INTEGER)"
      db.exec "INSERT INTO t VALUES (42)"
      expect_raises(DB::ColumnTypeMismatchError) do
        db.query_one("SELECT x FROM t", as: String?)
      end
    end
  end

  it "read(Int64) raises DB::ColumnTypeMismatchError for null value" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x INTEGER)"
      db.exec "INSERT INTO t VALUES (NULL)"
      expect_raises(DB::ColumnTypeMismatchError) do
        db.query_one("SELECT x FROM t", as: Int64)
      end
    end
  end

  it "read(String) raises DB::ColumnTypeMismatchError for null value" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x TEXT)"
      db.exec "INSERT INTO t VALUES (NULL)"
      expect_raises(DB::ColumnTypeMismatchError) do
        db.query_one("SELECT x FROM t", as: String)
      end
    end
  end

  it "read(Float64) raises DB::ColumnTypeMismatchError for null value" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (x REAL)"
      db.exec "INSERT INTO t VALUES (NULL)"
      expect_raises(DB::ColumnTypeMismatchError) do
        db.query_one("SELECT x FROM t", as: Float64)
      end
    end
  end

  it "read(Int32) works for pre-migration NOT NULL DEFAULT 0 column" do
    # read(Int32) calls read(Int64) — this now dispatches to our read(Int64.class)
    # which raises for nil. With the DEFAULT fix, pre-migration rows return 0 not nil.
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO t VALUES (1, 'test')"
      db.exec "ALTER TABLE t ADD COLUMN count INTEGER NOT NULL DEFAULT 0"
      val = db.query_one("SELECT count FROM t WHERE id = 1", as: Int32)
      val.should eq(0)
    end
  end
end
