require "../spec_helper"
require "../../src/trash_panda_db/replication/raft_log"

include TrashPandaDB::Replication

describe RaftLog do
  describe "in-memory" do
    it "starts with sentinel at index 0" do
      log = RaftLog.new
      log.last_index.should eq(0)
      log.last_term.should eq(0)
      log.term_at(0).should eq(0)
    end

    it "appends entries and updates last_index / last_term" do
      log = RaftLog.new
      e1 = log.append(1_i64, "INSERT INTO t VALUES (1)")
      e1.index.should eq(1)
      e1.term.should eq(1)
      log.last_index.should eq(1)
      log.last_term.should eq(1)

      e2 = log.append(1_i64, "INSERT INTO t VALUES (2)")
      e2.index.should eq(2)
      log.last_index.should eq(2)
    end

    it "entries_from returns entries after start" do
      log = RaftLog.new
      log.append(1_i64, "A")
      log.append(1_i64, "B")
      log.append(2_i64, "C")

      slice = log.entries_from(0_i64)
      slice.size.should eq(3)
      slice[0].sql.should eq("A")
      slice[2].sql.should eq("C")

      slice2 = log.entries_from(2_i64)
      slice2.size.should eq(1)
      slice2[0].sql.should eq("C")
    end

    it "append_entries accepts valid entries" do
      log = RaftLog.new
      log.append(1_i64, "X")

      entries = [LogEntry.new(1_i64, 2_i64, "Y")]
      ok = log.append_entries(1_i64, 1_i64, entries)
      ok.should be_true
      log.last_index.should eq(2)
    end

    it "append_entries rejects mismatched prev_term" do
      log = RaftLog.new
      log.append(1_i64, "X")

      entries = [LogEntry.new(2_i64, 2_i64, "Y")]
      ok = log.append_entries(1_i64, 2_i64, entries)  # prev_term mismatch
      ok.should be_false
      log.last_index.should eq(1)
    end

    it "append_entries truncates conflicting suffix" do
      log = RaftLog.new
      log.append(1_i64, "A")
      log.append(1_i64, "B")   # term 1 at index 2

      # Leader sends term 2 at index 2 — conflict, must truncate
      entries = [LogEntry.new(2_i64, 2_i64, "B2")]
      ok = log.append_entries(1_i64, 1_i64, entries)
      ok.should be_true
      log.last_index.should eq(2)
      log.term_at(2).should eq(2)
      log.entry_at(2).not_nil!.sql.should eq("B2")
    end
  end

  describe "edge cases" do
    it "term_at returns 0 for out-of-bounds indices" do
      log = RaftLog.new
      log.append(3_i64, "X")
      log.term_at(-1_i64).should eq(0)
      log.term_at(99_i64).should eq(0)
    end

    it "entry_at returns nil for out-of-bounds" do
      log = RaftLog.new
      log.append(1_i64, "X")
      log.entry_at(-1_i64).should be_nil
      log.entry_at(99_i64).should be_nil
    end

    it "entries_from returns empty when start >= last_index" do
      log = RaftLog.new
      log.append(1_i64, "A")
      log.entries_from(1_i64).should be_empty
      log.entries_from(99_i64).should be_empty
    end

    it "append_entries with empty new_entries is a valid heartbeat" do
      log = RaftLog.new
      log.append(1_i64, "A")
      ok = log.append_entries(1_i64, 1_i64, [] of LogEntry)
      ok.should be_true
      log.last_index.should eq(1)
    end

    it "append_entries with prev_index out of bounds is rejected" do
      log = RaftLog.new
      log.append(1_i64, "A")
      ok = log.append_entries(99_i64, 1_i64, [] of LogEntry)
      ok.should be_false
    end

    it "append_entries skips already-matching entries (idempotent)" do
      log = RaftLog.new
      log.append(1_i64, "A")
      log.append(1_i64, "B")

      # Send same entries again — same term, same index
      entries = [LogEntry.new(1_i64, 2_i64, "B")]
      ok = log.append_entries(1_i64, 1_i64, entries)
      ok.should be_true
      log.last_index.should eq(2)  # no duplicate appended
      log.entry_at(2).not_nil!.sql.should eq("B")
    end

    it "appends multiple entries across different terms" do
      log = RaftLog.new
      (1..5).each { |i| log.append(i.to_i64, "op-#{i}") }
      log.last_index.should eq(5)
      log.last_term.should eq(5)
      log.term_at(3).should eq(3)
    end
  end

  describe "persistence" do
    tmp_dir = "/tmp/raft_log_spec_#{Process.pid}"

    after_each do
      system("rm -rf #{tmp_dir}")
    end

    it "replays entries after reopen" do
      log = RaftLog.new(tmp_dir)
      log.append(1_i64, "CREATE TABLE t (id INTEGER)")
      log.append(1_i64, "INSERT INTO t VALUES (42)")
      log.close

      log2 = RaftLog.new(tmp_dir)
      log2.last_index.should eq(2)
      log2.entry_at(1).not_nil!.sql.should eq("CREATE TABLE t (id INTEGER)")
      log2.entry_at(2).not_nil!.sql.should eq("INSERT INTO t VALUES (42)")
      log2.close
    end

    it "rewrite_file survives truncation + reopen" do
      log = RaftLog.new(tmp_dir)
      log.append(1_i64, "A")
      log.append(1_i64, "B")
      log.append(1_i64, "C")

      # Simulate a conflict at index 2: entries with term 2 replace B and C
      entries = [LogEntry.new(2_i64, 2_i64, "B2"), LogEntry.new(2_i64, 3_i64, "C2")]
      log.append_entries(1_i64, 1_i64, entries)
      log.close

      log2 = RaftLog.new(tmp_dir)
      log2.last_index.should eq(3)
      log2.entry_at(2).not_nil!.sql.should eq("B2")
      log2.entry_at(3).not_nil!.sql.should eq("C2")
      log2.close
    end
  end
end
