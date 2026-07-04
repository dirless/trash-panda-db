require "./spec_helper"

private def vac_path
  "./test_vacuum_truncate.tpdb"
end

private def cleanup_vac
  File.delete(vac_path) rescue nil
  File.delete("#{vac_path}-wal") rescue nil
  File.delete("#{vac_path}.vacuum-tmp") rescue nil
  File.delete("#{vac_path}.vacuum-tmp-wal") rescue nil
end

describe "Truncating VACUUM (file-backed)" do
  before_each { cleanup_vac }
  after_each  { cleanup_vac }

  it "shrinks the file on disk after deleting most rows" do
    size_before = 0_i64
    size_after = 0_i64
    big = "x" * 3000

    DB.open "trashpanda:#{vac_path}" do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      200.times { |i| db.exec "INSERT INTO t (id, v) VALUES (?, ?)", i + 1, big }
      db.exec "DELETE FROM t WHERE id <= 190"

      size_before = File.size(vac_path)
      db.exec "VACUUM"
      size_after = File.size(vac_path)

      db.scalar("SELECT COUNT(*) FROM t").should eq 10_i64
      db.scalar("SELECT v FROM t WHERE id = 200").should eq big
    end

    size_after.should be < size_before
  end

  it "leaves no leftover tmp files after a normal VACUUM" do
    DB.open "trashpanda:#{vac_path}" do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 'a')"
      db.exec "VACUUM"
    end

    File.exists?("#{vac_path}.vacuum-tmp").should be_false
    File.exists?("#{vac_path}.vacuum-tmp-wal").should be_false
  end

  it "preserves data and indexes after a cold reopen following VACUUM" do
    DB.open "trashpanda:#{vac_path}" do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "CREATE INDEX idx_v ON t(v)"
      50.times { |i| db.exec "INSERT INTO t (id, v) VALUES (?, ?)", i + 1, "val#{i + 1}" }
      db.exec "DELETE FROM t WHERE id <= 40"
      db.exec "VACUUM"
    end

    DB.open "trashpanda:#{vac_path}" do |db|
      db.scalar("SELECT COUNT(*) FROM t").should eq 10_i64
      db.query_one("SELECT id FROM t WHERE v = ?", "val45", as: Int64).should eq 45_i64
      rows = db.query_all "EXPLAIN SELECT * FROM t WHERE v = 'val45'", as: String
      rows.any? { |r| r.downcase.includes?("index") }.should be_true
    end
  end

  it "keeps the original data intact if a stale .vacuum-tmp is left from a simulated crash" do
    DB.open "trashpanda:#{vac_path}" do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      30.times { |i| db.exec "INSERT INTO t (id, v) VALUES (?, ?)", i + 1, "v#{i + 1}" }
    end

    # Simulate a crash that happened mid-VACUUM, after the tmp file was
    # created but before it got renamed into place.
    File.write("#{vac_path}.vacuum-tmp", "garbage-partial-rebuild")
    File.write("#{vac_path}.vacuum-tmp-wal", "garbage-wal")

    DB.open "trashpanda:#{vac_path}" do |db|
      File.exists?("#{vac_path}.vacuum-tmp").should be_false
      File.exists?("#{vac_path}.vacuum-tmp-wal").should be_false
      db.scalar("SELECT COUNT(*) FROM t").should eq 30_i64
      db.scalar("SELECT v FROM t WHERE id = 15").should eq "v15"
    end
  end

  it "in-memory VACUUM still works without a file (existing behavior)" do
    with_mem_db do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      10.times { |i| db.exec "INSERT INTO t (id, v) VALUES (?, ?)", i + 1, "v#{i + 1}" }
      db.exec "DELETE FROM t WHERE id <= 5"
      db.exec "VACUUM"
      db.scalar("SELECT COUNT(*) FROM t").should eq 5_i64
    end
  end
end
