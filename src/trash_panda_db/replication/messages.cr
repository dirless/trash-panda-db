require "json"
require "./log_entry"

module TrashPandaDB::Replication
  # ── RPC message types ────────────────────────────────────────────────────────

  struct RequestVote
    include JSON::Serializable

    getter term : Int64
    getter candidate_id : String
    getter last_log_index : Int64
    getter last_log_term : Int64

    def initialize(@term, @candidate_id, @last_log_index, @last_log_term); end

    def to_wire : String
      %({"type":"RequestVote",) + to_json[1..]
    end
  end

  struct RequestVoteReply
    include JSON::Serializable

    getter term : Int64
    getter vote_granted : Bool

    def initialize(@term, @vote_granted); end

    def to_wire : String
      %({"type":"RequestVoteReply",) + to_json[1..]
    end
  end

  struct AppendEntries
    include JSON::Serializable

    getter term : Int64
    getter leader_id : String
    getter prev_log_index : Int64
    getter prev_log_term : Int64
    getter entries : Array(LogEntry)
    getter leader_commit : Int64

    def initialize(@term, @leader_id, @prev_log_index, @prev_log_term, @entries, @leader_commit); end

    def to_wire : String
      %({"type":"AppendEntries",) + to_json[1..]
    end
  end

  struct AppendEntriesReply
    include JSON::Serializable

    getter term : Int64
    getter success : Bool
    getter match_index : Int64  # last index the follower stored (for leader's nextIndex update)

    def initialize(@term, @success, @match_index); end

    def to_wire : String
      %({"type":"AppendEntriesReply",) + to_json[1..]
    end
  end

  struct PreVoteRequest
    include JSON::Serializable

    getter term : Int64
    getter candidate_id : String
    getter last_log_index : Int64
    getter last_log_term : Int64

    def initialize(@term, @candidate_id, @last_log_index, @last_log_term); end

    def to_wire : String
      %({"type":"PreVoteRequest",) + to_json[1..]
    end
  end

  struct PreVoteReply
    include JSON::Serializable

    getter term : Int64
    getter vote_granted : Bool

    def initialize(@term, @vote_granted); end

    def to_wire : String
      %({"type":"PreVoteReply",) + to_json[1..]
    end
  end

  struct InstallSnapshot
    include JSON::Serializable

    getter term : Int64
    getter leader_id : String
    getter last_included_index : Int64
    getter last_included_term : Int64
    getter data : String   # base64-encoded chunk bytes
    getter offset : Int64  # byte offset of this chunk in the snapshot file
    getter done : Bool     # true iff this is the last chunk

    def initialize(@term, @leader_id, @last_included_index, @last_included_term, @data, @offset, @done); end

    def to_wire : String
      %({"type":"InstallSnapshot",) + to_json[1..]
    end
  end

  struct InstallSnapshotReply
    include JSON::Serializable

    getter term : Int64
    getter success : Bool

    def initialize(@term, @success); end

    def to_wire : String
      %({"type":"InstallSnapshotReply",) + to_json[1..]
    end
  end

  # Dispatch from a raw wire line to a typed message.
  def self.parse_message(line : String) : RequestVote | RequestVoteReply | AppendEntries | AppendEntriesReply | PreVoteRequest | PreVoteReply | InstallSnapshot | InstallSnapshotReply
    parsed = JSON.parse(line)
    type = parsed["type"].as_s
    case type
    when "RequestVote"          then RequestVote.from_json(line)
    when "RequestVoteReply"     then RequestVoteReply.from_json(line)
    when "AppendEntries"        then AppendEntries.from_json(line)
    when "AppendEntriesReply"   then AppendEntriesReply.from_json(line)
    when "PreVoteRequest"       then PreVoteRequest.from_json(line)
    when "PreVoteReply"         then PreVoteReply.from_json(line)
    when "InstallSnapshot"      then InstallSnapshot.from_json(line)
    when "InstallSnapshotReply" then InstallSnapshotReply.from_json(line)
    else
      raise "unknown message type: #{type}"
    end
  end
end
