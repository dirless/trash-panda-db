require "./spec_helper"

describe "Scalar subquery — (SELECT ...) as expression" do
  it "returns a scalar value from a subquery in SELECT" do
    with_mem_db do |db|
      db.exec "CREATE TABLE config (key TEXT, value INTEGER)"
      db.exec "INSERT INTO config VALUES ('max', 100)"

      result = db.query_one("SELECT (SELECT value FROM config WHERE key = 'max')", as: Int64)
      result.should eq(100_i64)
    end
  end

  it "returns nil when scalar subquery matches no rows" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
      db.exec "INSERT INTO t VALUES (1)"

      result = db.query_one("SELECT (SELECT id FROM t WHERE id = 999)", as: Int64?)
      result.should be_nil
    end
  end

  it "supports scalar subquery in WHERE clause comparison" do
    with_mem_db do |db|
      db.exec "CREATE TABLE settings (name TEXT, threshold INTEGER)"
      db.exec "CREATE TABLE readings (id INTEGER PRIMARY KEY, value INTEGER)"
      db.exec "INSERT INTO settings VALUES ('limit', 50)"
      db.exec "INSERT INTO readings VALUES (1, 30)"
      db.exec "INSERT INTO readings VALUES (2, 70)"

      ids = db.query_all(
        "SELECT id FROM readings WHERE value > (SELECT threshold FROM settings WHERE name = 'limit')",
        as: Int64
      )
      ids.should eq([2_i64])
    end
  end

  it "supports scalar subquery in UPDATE SET clause" do
    with_mem_db do |db|
      db.exec "CREATE TABLE src (name TEXT, score INTEGER)"
      db.exec "CREATE TABLE dst (name TEXT, score INTEGER)"
      db.exec "INSERT INTO src VALUES ('alice', 42)"
      db.exec "INSERT INTO dst VALUES ('alice', 0)"

      db.exec "UPDATE dst SET score = (SELECT score FROM src WHERE src.name = 'alice')"

      score = db.query_one("SELECT score FROM dst WHERE name = 'alice'", as: Int64)
      score.should eq(42_i64)
    end
  end

  it "supports scalar subquery in INSERT VALUES" do
    with_mem_db do |db|
      db.exec "CREATE TABLE lookup (val INTEGER)"
      db.exec "CREATE TABLE target (n INTEGER)"
      db.exec "INSERT INTO lookup VALUES (99)"

      db.exec "INSERT INTO target VALUES ((SELECT val FROM lookup LIMIT 1))"

      n = db.query_one("SELECT n FROM target", as: Int64)
      n.should eq(99_i64)
    end
  end

  it "backfill UPDATE with scalar subquery joining two tables" do
    # Simulates the dirless-ops db.cr backfill migration:
    # UPDATE customers SET email = (SELECT email FROM customer_accounts WHERE customer_name = customers.name)
    # This is a correlated subquery — the outer table's value is used in the inner WHERE.
    # For simple non-correlated lookups it works; correlated queries raise "no such column".
    with_mem_db do |db|
      db.exec "CREATE TABLE accounts (email TEXT, customer_name TEXT)"
      db.exec "CREATE TABLE customers (name TEXT, email TEXT)"
      db.exec "INSERT INTO accounts VALUES ('alice@example.com', 'alice')"
      db.exec "INSERT INTO accounts VALUES ('bob@example.com', 'bob')"
      db.exec "INSERT INTO customers VALUES ('alice', NULL)"
      db.exec "INSERT INTO customers VALUES ('bob', NULL)"

      # Non-correlated: set all emails to the first account's email
      db.exec "UPDATE customers SET email = (SELECT email FROM accounts WHERE customer_name = 'alice')"

      # All customers get alice's email (non-correlated subquery returns same value for all)
      emails = db.query_all("SELECT email FROM customers ORDER BY name", as: String)
      emails.should eq(["alice@example.com", "alice@example.com"])
    end
  end
end
