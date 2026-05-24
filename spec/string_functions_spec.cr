require "./spec_helper"

describe "SQL string and scalar functions" do
  describe "INSTR" do
    it "returns 1-based position when needle found" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (s TEXT)"
        db.exec "INSERT INTO t (s) VALUES ('hello world')"
        pos = db.query_one "SELECT INSTR(s, 'world') FROM t", as: Int64
        pos.should eq(7_i64)
      end
    end

    it "returns 0 when needle not found" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (s TEXT)"
        db.exec "INSERT INTO t (s) VALUES ('hello')"
        pos = db.query_one "SELECT INSTR(s, 'xyz') FROM t", as: Int64
        pos.should eq(0_i64)
      end
    end

    it "returns 1 when needle is at start" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (s TEXT)"
        db.exec "INSERT INTO t (s) VALUES ('abc')"
        pos = db.query_one "SELECT INSTR(s, 'a') FROM t", as: Int64
        pos.should eq(1_i64)
      end
    end

    it "returns NULL when either arg is NULL" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (s TEXT)"
        db.exec "INSERT INTO t (s) VALUES (NULL)"
        result = db.query_one "SELECT INSTR(s, 'x') FROM t", as: Int64?
        result.should be_nil
      end
    end

    it "works with literal strings" do
      with_mem_db do |db|
        result = db.scalar "SELECT INSTR('abcdef', 'cd')"
        result.as(Int64).should eq(3_i64)
      end
    end
  end

  describe "SUBSTR / SUBSTRING" do
    it "extracts a substring from position with length" do
      with_mem_db do |db|
        result = db.scalar "SELECT SUBSTR('abcdef', 2, 3)"
        result.as(String).should eq("bcd")
      end
    end

    it "extracts from position to end when no length given" do
      with_mem_db do |db|
        result = db.scalar "SELECT SUBSTR('abcdef', 3)"
        result.as(String).should eq("cdef")
      end
    end

    it "supports SUBSTRING alias" do
      with_mem_db do |db|
        result = db.scalar "SELECT SUBSTRING('hello', 2, 3)"
        result.as(String).should eq("ell")
      end
    end

    it "handles negative start (counts from end)" do
      with_mem_db do |db|
        # SQLite: SUBSTR('abcdef', -2) = 'ef'
        result = db.scalar "SELECT SUBSTR('abcdef', -2)"
        result.as(String).should eq("ef")
      end
    end

    it "returns empty string when start is past end" do
      with_mem_db do |db|
        result = db.scalar "SELECT SUBSTR('abc', 10)"
        result.as(String).should eq("")
      end
    end

    it "returns NULL on NULL input" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (s TEXT)"
        db.exec "INSERT INTO t (s) VALUES (NULL)"
        result = db.query_one "SELECT SUBSTR(s, 1, 2) FROM t", as: String?
        result.should be_nil
      end
    end
  end

  describe "LENGTH" do
    it "returns string length" do
      with_mem_db do |db|
        result = db.scalar "SELECT LENGTH('hello')"
        result.as(Int64).should eq(5_i64)
      end
    end

    it "returns 0 for empty string" do
      with_mem_db do |db|
        result = db.scalar "SELECT LENGTH('')"
        result.as(Int64).should eq(0_i64)
      end
    end

    it "returns NULL for NULL" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (s TEXT)"
        db.exec "INSERT INTO t (s) VALUES (NULL)"
        result = db.query_one "SELECT LENGTH(s) FROM t", as: Int64?
        result.should be_nil
      end
    end
  end

  describe "UPPER / LOWER" do
    it "UPPER converts to uppercase" do
      with_mem_db do |db|
        result = db.scalar "SELECT UPPER('hello World')"
        result.as(String).should eq("HELLO WORLD")
      end
    end

    it "LOWER converts to lowercase" do
      with_mem_db do |db|
        result = db.scalar "SELECT LOWER('Hello WORLD')"
        result.as(String).should eq("hello world")
      end
    end
  end

  describe "TRIM / LTRIM / RTRIM" do
    it "TRIM removes surrounding whitespace" do
      with_mem_db do |db|
        result = db.scalar "SELECT TRIM('  hello  ')"
        result.as(String).should eq("hello")
      end
    end

    it "LTRIM removes leading whitespace" do
      with_mem_db do |db|
        result = db.scalar "SELECT LTRIM('  hello  ')"
        result.as(String).should eq("hello  ")
      end
    end

    it "RTRIM removes trailing whitespace" do
      with_mem_db do |db|
        result = db.scalar "SELECT RTRIM('  hello  ')"
        result.as(String).should eq("  hello")
      end
    end

    it "TRIM with chars argument removes those characters" do
      with_mem_db do |db|
        result = db.scalar "SELECT TRIM('xxhelloxx', 'x')"
        result.as(String).should eq("hello")
      end
    end
  end

  describe "REPLACE" do
    it "replaces all occurrences of a substring" do
      with_mem_db do |db|
        result = db.scalar "SELECT REPLACE('hello world world', 'world', 'earth')"
        result.as(String).should eq("hello earth earth")
      end
    end

    it "returns original string when pattern not found" do
      with_mem_db do |db|
        result = db.scalar "SELECT REPLACE('hello', 'xyz', 'abc')"
        result.as(String).should eq("hello")
      end
    end
  end

  describe "CAST" do
    it "CAST(text AS INTEGER) converts to integer" do
      with_mem_db do |db|
        result = db.scalar "SELECT CAST('42' AS INTEGER)"
        result.as(Int64).should eq(42_i64)
      end
    end

    it "CAST(real AS INTEGER) truncates" do
      with_mem_db do |db|
        result = db.scalar "SELECT CAST(3.9 AS INTEGER)"
        result.as(Int64).should eq(3_i64)
      end
    end

    it "CAST(integer AS REAL) promotes to float" do
      with_mem_db do |db|
        result = db.scalar "SELECT CAST(5 AS REAL)"
        result.as(Float64).should eq(5.0)
      end
    end

    it "CAST(number AS TEXT) converts to string" do
      with_mem_db do |db|
        result = db.scalar "SELECT CAST(123 AS TEXT)"
        result.as(String).should eq("123")
      end
    end
  end

  describe "ABS" do
    it "returns absolute value of negative integer" do
      with_mem_db do |db|
        result = db.scalar "SELECT ABS(-42)"
        result.as(Int64).should eq(42_i64)
      end
    end

    it "returns absolute value of negative float" do
      with_mem_db do |db|
        result = db.scalar "SELECT ABS(-3.14)"
        result.as(Float64).should eq(3.14)
      end
    end

    it "passes through positive values unchanged" do
      with_mem_db do |db|
        result = db.scalar "SELECT ABS(7)"
        result.as(Int64).should eq(7_i64)
      end
    end
  end

  describe "ROUND" do
    it "rounds to nearest integer by default" do
      with_mem_db do |db|
        result = db.scalar "SELECT ROUND(3.6)"
        result.as(Int64).should eq(4_i64)
      end
    end

    it "rounds down correctly" do
      with_mem_db do |db|
        result = db.scalar "SELECT ROUND(3.4)"
        result.as(Int64).should eq(3_i64)
      end
    end

    it "rounds to specified decimal places" do
      with_mem_db do |db|
        result = db.scalar "SELECT ROUND(3.14159, 2)"
        result.as(Float64).should be_close(3.14, 1e-9)
      end
    end
  end

  describe "combined usage" do
    it "INSTR used in WHERE clause" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "INSERT INTO t (name) VALUES ('alice-5000')"
        db.exec "INSERT INTO t (name) VALUES ('bob-5001')"
        db.exec "INSERT INTO t (name) VALUES ('charlie')"

        names = db.query_all(
          "SELECT name FROM t WHERE INSTR(name, '-') > 0",
          as: String
        ).sort
        names.should eq(["alice-5000", "bob-5001"])
      end
    end

    it "SUBSTR used in SELECT" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, code TEXT)"
        db.exec "INSERT INTO t (code) VALUES ('US-NY-001')"
        db.exec "INSERT INTO t (code) VALUES ('US-CA-002')"

        states = db.query_all(
          "SELECT SUBSTR(code, 4, 2) FROM t ORDER BY code",
          as: String
        )
        states.should eq(["CA", "NY"])
      end
    end
  end
end
