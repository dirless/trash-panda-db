require "./spec_helper"

TX_DB = "./test_txn.tpdb"

private def cleanup_tx
  File.delete(TX_DB) rescue nil
  File.delete("#{TX_DB}-wal") rescue nil
end

describe "Transactions" do
  describe "basic commit and rollback" do
    it "committed inserts are visible after commit" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.transaction do |tx|
          tx.connection.exec "INSERT INTO t (v) VALUES (?)", "hello"
        end
        db.scalar("SELECT COUNT(*) FROM t").should eq(1_i64)
      end
    end

    it "rolled-back inserts are not visible" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.transaction do |tx|
          tx.connection.exec "INSERT INTO t (v) VALUES (?)", "hello"
          tx.rollback
        end
        db.scalar("SELECT COUNT(*) FROM t").should eq(0_i64)
      end
    end

    it "committed updates are visible after commit" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.exec "INSERT INTO t (v) VALUES (?)", "old"
        db.transaction do |tx|
          tx.connection.exec "UPDATE t SET v = ? WHERE v = ?", "new", "old"
        end
        db.scalar("SELECT v FROM t").should eq("new")
      end
    end

    it "rolled-back updates are not visible" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.exec "INSERT INTO t (v) VALUES (?)", "old"
        db.transaction do |tx|
          tx.connection.exec "UPDATE t SET v = ? WHERE v = ?", "new", "old"
          tx.rollback
        end
        db.scalar("SELECT v FROM t").should eq("old")
      end
    end

    it "committed deletes are visible after commit" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.exec "INSERT INTO t (v) VALUES (?)", "gone"
        db.transaction do |tx|
          tx.connection.exec "DELETE FROM t WHERE v = ?", "gone"
        end
        db.scalar("SELECT COUNT(*) FROM t").should eq(0_i64)
      end
    end

    it "rolled-back deletes are not visible" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.exec "INSERT INTO t (v) VALUES (?)", "kept"
        db.transaction do |tx|
          tx.connection.exec "DELETE FROM t WHERE v = ?", "kept"
          tx.rollback
        end
        db.scalar("SELECT COUNT(*) FROM t").should eq(1_i64)
      end
    end
  end

  describe "read-your-own-writes within a transaction" do
    it "sees inserted rows within the same transaction" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.transaction do |tx|
          conn = tx.connection
          conn.exec "INSERT INTO t (v) VALUES (?)", "a"
          conn.exec "INSERT INTO t (v) VALUES (?)", "b"
          count = conn.scalar("SELECT COUNT(*) FROM t").as(Int64)
          count.should eq(2_i64)
        end
      end
    end

    it "sees updated rows within the same transaction" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.exec "INSERT INTO t (v) VALUES (?)", "before"
        db.transaction do |tx|
          conn = tx.connection
          conn.exec "UPDATE t SET v = ? WHERE v = ?", "after", "before"
          val = conn.scalar("SELECT v FROM t").as(String)
          val.should eq("after")
        end
      end
    end

    it "sees deleted rows gone within the same transaction" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.exec "INSERT INTO t (v) VALUES (?)", "remove_me"
        db.transaction do |tx|
          conn = tx.connection
          conn.exec "DELETE FROM t WHERE v = ?", "remove_me"
          count = conn.scalar("SELECT COUNT(*) FROM t").as(Int64)
          count.should eq(0_i64)
        end
      end
    end
  end

  describe "savepoints" do
    it "nested savepoint commit keeps changes" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.transaction do |tx|
          conn = tx.connection
          conn.exec "INSERT INTO t (v) VALUES (?)", "outer"
          conn.exec "SAVEPOINT sp1"
          conn.exec "INSERT INTO t (v) VALUES (?)", "inner"
          conn.exec "RELEASE SAVEPOINT sp1"
          count = conn.scalar("SELECT COUNT(*) FROM t").as(Int64)
          count.should eq(2_i64)
        end
        db.scalar("SELECT COUNT(*) FROM t").should eq(2_i64)
      end
    end

    it "savepoint rollback discards only the nested changes" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.transaction do |tx|
          conn = tx.connection
          conn.exec "INSERT INTO t (v) VALUES (?)", "outer"
          conn.exec "SAVEPOINT sp1"
          conn.exec "INSERT INTO t (v) VALUES (?)", "inner"
          conn.exec "ROLLBACK TO sp1"
          count = conn.scalar("SELECT COUNT(*) FROM t").as(Int64)
          count.should eq(1_i64)
        end
        db.scalar("SELECT COUNT(*) FROM t").should eq(1_i64)
      end
    end
  end

  describe "persistence" do
    it "committed transaction data survives reopen" do
      cleanup_tx
      DB.open "trashpanda:#{TX_DB}" do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.transaction do |tx|
          tx.connection.exec "INSERT INTO t (v) VALUES (?)", "persisted"
        end
      end

      DB.open "trashpanda:#{TX_DB}" do |db|
        val = db.scalar("SELECT v FROM t").as(String)
        val.should eq("persisted")
      end
    ensure
      cleanup_tx
    end

    it "rolled-back transaction data does not survive reopen" do
      cleanup_tx
      DB.open "trashpanda:#{TX_DB}" do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
        db.exec "INSERT INTO t (v) VALUES (?)", "committed"
        db.transaction do |tx|
          tx.connection.exec "INSERT INTO t (v) VALUES (?)", "ephemeral"
          tx.rollback
        end
      end

      DB.open "trashpanda:#{TX_DB}" do |db|
        count = db.scalar("SELECT COUNT(*) FROM t").as(Int64)
        count.should eq(1_i64)
        val = db.scalar("SELECT v FROM t").as(String)
        val.should eq("committed")
      end
    ensure
      cleanup_tx
    end
  end
end
