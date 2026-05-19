require "json"
require "./log_entry"

module TrashPandaDB::Replication
  # Append-only log persisted as JSONL (one entry per line).
  # Index is 1-based; slot 0 is a sentinel with term=0, used for prev-log checks.
  class RaftLog
    getter entries : Array(LogEntry)
    @path : String?
    @file : File?

    def initialize(data_dir : String? = nil)
      @entries = [LogEntry.new(0_i64, 0_i64, "")]  # sentinel at index 0
      if dir = data_dir
        @path = File.join(dir, "raft_log.jsonl")
        Dir.mkdir_p(dir)
        replay
        @file = File.open(@path.not_nil!, "a")
      end
    end

    def last_index : Int64
      (@entries.size - 1).to_i64
    end

    def last_term : Int64
      @entries.last.term
    end

    def term_at(index : Int64) : Int64
      return 0_i64 if index < 0 || index >= @entries.size
      @entries[index].term
    end

    def entry_at(index : Int64) : LogEntry?
      return nil if index < 0 || index >= @entries.size
      @entries[index]
    end

    # Append a SQL (or no-op) entry and persist it.
    def append(term : Int64, sql : String) : LogEntry
      idx = last_index + 1
      entry = LogEntry.sql_entry(term, idx, sql)
      @entries << entry
      persist(entry)
      entry
    end

    # Append a membership-change entry and persist it.
    def append_add_node(term : Int64, node_id : String, raft_addr : String, client_addr : String) : LogEntry
      idx = last_index + 1
      entry = LogEntry.add_node(term, idx, node_id, raft_addr, client_addr)
      @entries << entry
      persist(entry)
      entry
    end

    # Append entries from a leader, truncating any conflicting suffix.
    # Returns true if any entries were newly appended.
    def append_entries(prev_index : Int64, prev_term : Int64, new_entries : Array(LogEntry)) : Bool
      return false if prev_index >= @entries.size
      return false if term_at(prev_index) != prev_term

      new_entries.each_with_index do |entry, i|
        slot = (prev_index + 1 + i).to_i32
        if slot < @entries.size
          if @entries[slot].term != entry.term
            truncate_from(slot)
            @entries << entry
            persist(entry)
          end
          # else: already have this entry, skip
        else
          @entries << entry
          persist(entry)
        end
      end
      true
    end

    # Entries from (start+1) to last_index, inclusive.
    def entries_from(start : Int64) : Array(LogEntry)
      first = (start + 1).to_i32
      return [] of LogEntry if first >= @entries.size
      @entries[first..]
    end

    private def truncate_from(slot : Int32)
      @entries = @entries[0...slot]
      rewrite_file
    end

    private def replay
      path = @path.not_nil!
      return unless File.exists?(path)
      File.each_line(path) do |line|
        line = line.strip
        next if line.empty?
        begin
          @entries << LogEntry.from_json(line)
        rescue
          # skip corrupt lines
        end
      end
    end

    private def persist(entry : LogEntry)
      if f = @file
        f.puts(entry.to_json)
        f.flush
      end
    end

    private def rewrite_file
      if f = @file
        f.close
      end
      if path = @path
        tmp = path + ".tmp"
        File.open(tmp, "w") do |f|
          @entries.each_with_index do |e, i|
            next if i == 0  # skip sentinel
            f.puts(e.to_json)
          end
        end
        File.rename(tmp, path)
        @file = File.open(path, "a")
      end
    end

    def close
      @file.try &.close
    end
  end
end
