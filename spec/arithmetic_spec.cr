require "./spec_helper"

describe "SQL arithmetic operators" do
  it "adds two integers" do
    with_mem_db do |db|
      db.query_one("SELECT 2 + 3", as: Int64).should eq(5_i64)
    end
  end

  it "subtracts integers" do
    with_mem_db do |db|
      db.query_one("SELECT 10 - 4", as: Int64).should eq(6_i64)
    end
  end

  it "multiplies integers" do
    with_mem_db do |db|
      db.query_one("SELECT 3 * 7", as: Int64).should eq(21_i64)
    end
  end

  it "divides integers (truncating)" do
    with_mem_db do |db|
      db.query_one("SELECT 10 / 3", as: Int64).should eq(3_i64)
    end
  end

  it "handles operator precedence (* before +)" do
    with_mem_db do |db|
      db.query_one("SELECT 2 + 3 * 4", as: Int64).should eq(14_i64)
    end
  end

  it "handles parentheses" do
    with_mem_db do |db|
      db.query_one("SELECT (2 + 3) * 4", as: Int64).should eq(20_i64)
    end
  end

  it "supports arithmetic in WHERE clause" do
    with_mem_db do |db|
      db.exec "CREATE TABLE nums (n INTEGER)"
      db.exec "INSERT INTO nums VALUES (5)"
      db.exec "INSERT INTO nums VALUES (10)"
      result = db.query_one("SELECT n FROM nums WHERE n > 3 + 4", as: Int64)
      result.should eq(10_i64)
    end
  end

  it "supports INSTR + 1 (the registration port query)" do
    with_mem_db do |db|
      db.exec "CREATE TABLE customers (name TEXT)"
      db.exec "INSERT INTO customers VALUES ('abcdef-5000')"
      db.exec "INSERT INTO customers VALUES ('ghijkl-5001')"
      db.exec "INSERT INTO customers VALUES ('mnopqr-5002')"
      max_port = db.scalar(
        "SELECT MAX(CAST(SUBSTR(name, INSTR(name, '-') + 1) AS INTEGER)) FROM customers " \
        "WHERE CAST(SUBSTR(name, INSTR(name, '-') + 1) AS INTEGER) >= 5000"
      )
      max_port.should eq(5002_i64)
    end
  end

  it "handles unary minus" do
    with_mem_db do |db|
      db.query_one("SELECT -5", as: Int64).should eq(-5_i64)
    end
  end

  it "handles float arithmetic" do
    with_mem_db do |db|
      result = db.query_one("SELECT 1.5 + 2.5", as: Float64)
      result.should eq(4.0)
    end
  end
end
