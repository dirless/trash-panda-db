require "json"

module TrashPandaDB::Replication
  # A single entry in the Raft replicated log.
  # `sql` is the statement to replay; args are already inlined so the command
  # is fully self-contained (no ? placeholders remain).
  struct LogEntry
    include JSON::Serializable

    getter term : Int64
    getter index : Int64
    getter sql : String

    def initialize(@term : Int64, @index : Int64, @sql : String); end
  end
end
