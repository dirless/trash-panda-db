require "json"
require "./log_entry"

module TrashPandaDB::Replication
  # Append-only log persisted as JSONL (one entry per line).
  # Index is offset by @base_index: @entries[0] is the sentinel at index @base_index,
  # @entries[1] is at index @base_index+1, etc. When base_index=0 (no snapshot),
  # the sentinel is at index 0 with term=0, used for prev-log checks.
  class RaftLog
    getter entries : Array(LogEntry)
    getter base_index : Int64
    @base_term : Int64
    @path : String?
    @meta_path : String?
    @file : File?

    def initialize(data_dir : String? = nil)
      @base_index = 0_i64
      @base_term = 0_i64
      if dir = data_dir
        @path = File.join(dir, "raft_log.jsonl")
        @meta_path = File.join(dir, "raft_log_meta.json")
        Dir.mkdir_p(dir)
        read_log_meta
        @entries = [LogEntry.new(@base_term, @base_index, "")]
        replay
        @file = File.open(@path.not_nil!, "a")
      else
        @entries = [LogEntry.new(0_i64, 0_i64, "")]
      end
    end

    def last_index : Int64
      @base_index + @entries.size - 1
    end

    def last_term : Int64
      @entries.last.term
    end

    def term_at(index : Int64) : Int64
      return 0_i64 if index < @base_index
      slot = (index - @base_index).to_i32
      return 0_i64 if slot >= @entries.size
      @entries[slot].term
    end

    def entry_at(index : Int64) : LogEntry?
      return nil if index < @base_index
      slot = (index - @base_index).to_i32
      return nil if slot >= @entries.size
      @entries[slot]
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
      return false if prev_index < @base_index
      return false if term_at(prev_index) != prev_term

      base_slot = (prev_index - @base_index).to_i32
      new_entries.each_with_index do |entry, i|
        slot = (base_slot + 1 + i).to_i32
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
    # Optional limit caps the slice so AppendEntries messages stay small.
    def entries_from(start : Int64, limit : Int32 = Int32::MAX) : Array(LogEntry)
      first = (start + 1 - @base_index).to_i32
      return [] of LogEntry if first >= @entries.size
      slice = @entries[first..]
      limit < slice.size ? slice[0, limit] : slice
    end

    # Returns all entries strictly after the given index.
    def entries_after(index : Int64) : Array(LogEntry)
      slot = (index + 1 - @base_index).to_i32
      return [] of LogEntry if slot >= @entries.size
      @entries[slot..]
    end

    # Replace entire log with snapshot sentinel + remaining entries.
    # Rewrites both log metadata and the log file.
    def install_snapshot(snapshot_index : Int64, snapshot_term : Int64, remaining_entries : Array(LogEntry)) : Nil
      @base_index = snapshot_index
      @base_term = snapshot_term
      sentinel = LogEntry.new(snapshot_term, snapshot_index, "")
      @entries = [sentinel] + remaining_entries
      write_log_meta
      rewrite_file
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
        f.fsync
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
          f.fsync
        end
        File.rename(tmp, path)
        @file = File.open(path, "a")
      end
    end

    # ── Log metadata persistence ──────────────────────────────────────────────

    private def write_log_meta
      mpath = @meta_path || return
      tmp = mpath + ".tmp"
      File.open(tmp, "w") { |f| f.print(%({"base_index":#{@base_index},"base_term":#{@base_term}})); f.fsync }
      File.rename(tmp, mpath)
      File.open(File.dirname(mpath), "r") { |f| f.fsync } rescue nil
    end

    private def read_log_meta
      mpath = @meta_path || return
      return unless File.exists?(mpath)
      data = File.read(mpath)
      parsed = JSON.parse(data)
      @base_index = parsed["base_index"].as_i64
      @base_term = parsed["base_term"].as_i64
    rescue
      # corrupt or missing — leave defaults at 0
    end

    def close
      @file.try &.close
    end
  end
end
