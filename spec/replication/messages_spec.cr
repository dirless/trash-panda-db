require "../spec_helper"
require "../../src/trash_panda_db/replication/messages"
require "../../src/trash_panda_db/replication/log_entry"

include TrashPandaDB::Replication

describe "Replication messages" do
  describe RequestVote do
    it "round-trips through JSON" do
      msg = RequestVote.new(3_i64, "n1", 5_i64, 2_i64)
      msg2 = RequestVote.from_json(msg.to_json)
      msg2.term.should eq(3)
      msg2.candidate_id.should eq("n1")
      msg2.last_log_index.should eq(5)
      msg2.last_log_term.should eq(2)
    end

    it "to_wire injects type field" do
      wire = RequestVote.new(1_i64, "n2", 0_i64, 0_i64).to_wire
      parsed = JSON.parse(wire)
      parsed["type"].as_s.should eq("RequestVote")
      parsed["candidate_id"].as_s.should eq("n2")
    end
  end

  describe RequestVoteReply do
    it "round-trips granted=true" do
      wire = RequestVoteReply.new(2_i64, true).to_wire
      parsed = JSON.parse(wire)
      parsed["type"].as_s.should eq("RequestVoteReply")
      parsed["vote_granted"].as_bool.should be_true
    end

    it "round-trips granted=false" do
      r = RequestVoteReply.from_json(RequestVoteReply.new(1_i64, false).to_json)
      r.vote_granted.should be_false
    end
  end

  describe AppendEntries do
    it "round-trips with entries" do
      entries = [LogEntry.new(1_i64, 1_i64, "INSERT INTO t VALUES (1)")]
      msg = AppendEntries.new(1_i64, "n1", 0_i64, 0_i64, entries, 0_i64)
      msg2 = AppendEntries.from_json(msg.to_json)
      msg2.leader_id.should eq("n1")
      msg2.entries.size.should eq(1)
      msg2.entries[0].sql.should eq("INSERT INTO t VALUES (1)")
    end

    it "to_wire includes type and leader_commit" do
      wire = AppendEntries.new(2_i64, "n3", 4_i64, 1_i64, [] of LogEntry, 3_i64).to_wire
      parsed = JSON.parse(wire)
      parsed["type"].as_s.should eq("AppendEntries")
      parsed["leader_commit"].as_i64.should eq(3)
    end
  end

  describe AppendEntriesReply do
    it "round-trips success with match_index" do
      r = AppendEntriesReply.new(1_i64, true, 7_i64)
      r2 = AppendEntriesReply.from_json(r.to_json)
      r2.success.should be_true
      r2.match_index.should eq(7)
    end
  end

  describe InstallSnapshot do
    it "round-trips a non-final chunk" do
      msg = InstallSnapshot.new(3_i64, "n1", 10_i64, 2_i64, "AAAA", 0_i64, false)
      msg2 = InstallSnapshot.from_json(msg.to_json)
      msg2.term.should eq(3)
      msg2.leader_id.should eq("n1")
      msg2.last_included_index.should eq(10)
      msg2.last_included_term.should eq(2)
      msg2.data.should eq("AAAA")
      msg2.offset.should eq(0)
      msg2.done.should be_false
    end

    it "round-trips the final chunk with non-zero offset" do
      msg = InstallSnapshot.new(5_i64, "n2", 20_i64, 4_i64, "BBBB", 262144_i64, true)
      wire = msg.to_wire
      parsed = JSON.parse(wire)
      parsed["type"].as_s.should eq("InstallSnapshot")
      parsed["offset"].as_i64.should eq(262144)
      parsed["done"].as_bool.should be_true
      msg2 = InstallSnapshot.from_json(msg.to_json)
      msg2.offset.should eq(262144)
      msg2.done.should be_true
    end
  end

  describe "parse_message" do
    it "dispatches RequestVote" do
      wire = RequestVote.new(1_i64, "n1", 0_i64, 0_i64).to_wire
      msg = Replication.parse_message(wire)
      msg.should be_a(RequestVote)
    end

    it "dispatches RequestVoteReply" do
      wire = RequestVoteReply.new(1_i64, true).to_wire
      msg = Replication.parse_message(wire)
      msg.should be_a(RequestVoteReply)
    end

    it "dispatches AppendEntries" do
      wire = AppendEntries.new(1_i64, "n1", 0_i64, 0_i64, [] of LogEntry, 0_i64).to_wire
      msg = Replication.parse_message(wire)
      msg.should be_a(AppendEntries)
    end

    it "dispatches AppendEntriesReply" do
      wire = AppendEntriesReply.new(1_i64, false, 0_i64).to_wire
      msg = Replication.parse_message(wire)
      msg.should be_a(AppendEntriesReply)
    end

    it "raises on unknown type" do
      expect_raises(Exception) do
        Replication.parse_message(%({"type":"Unknown","x":1}))
      end
    end
  end
end
