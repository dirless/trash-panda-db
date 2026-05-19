require "json"

module TrashPandaDB::Replication
  # A single entry in the Raft replicated log.
  #
  # type = "sql"  — SQL statement to execute (args already inlined)
  # type = "add"  — cluster membership change: add a new node
  #
  # The `type` field defaults to "sql" so existing JSONL logs without
  # the field continue to deserialize correctly.
  struct LogEntry
    include JSON::Serializable

    getter term  : Int64
    getter index : Int64

    @[JSON::Field(key: "type")]
    getter entry_type : String = "sql"

    getter sql : String = ""

    # Membership-change fields (present only when entry_type == "add")
    @[JSON::Field(emit_null: false)]
    getter node_id : String?

    @[JSON::Field(emit_null: false)]
    getter raft_addr : String?

    @[JSON::Field(emit_null: false)]
    getter client_addr : String?

    def initialize(
      @term : Int64,
      @index : Int64,
      @sql : String = "",
      @entry_type : String = "sql",
      @node_id : String? = nil,
      @raft_addr : String? = nil,
      @client_addr : String? = nil
    ); end

    def self.sql_entry(term : Int64, index : Int64, sql : String) : LogEntry
      new(term, index, sql)
    end

    def self.add_node(term : Int64, index : Int64, node_id : String, raft_addr : String, client_addr : String) : LogEntry
      new(term, index, "", "add", node_id, raft_addr, client_addr)
    end
  end
end
