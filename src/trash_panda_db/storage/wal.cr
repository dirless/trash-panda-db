require "./constants"

module TrashPandaDB::Storage
  # Write-ahead log. Frames are appended sequentially; a commit frame (flag bit 0)
  # makes all preceding unflushed frames durable. The WAL is replayed on open if
  # the previous session crashed before checkpoint.
  #
  # Thread/fiber safety: callers hold the connection mutex; WAL itself is unsynchronized.
  class WAL
    # page_no (1-based) → page bytes for committed frames not yet checkpointed
    getter committed : Hash(UInt32, Bytes)

    # page_no → page bytes for the current (not yet committed) transaction
    getter dirty : Hash(UInt32, Bytes)

    # Stack of (savepoint_name, snapshot_of_dirty) pairs.
    @savepoints = Array(Tuple(String, Hash(UInt32, Bytes))).new

    def initialize(@path : String | Nil)
      @committed = Hash(UInt32, Bytes).new
      @dirty     = Hash(UInt32, Bytes).new
      @savepoints = Array(Tuple(String, Hash(UInt32, Bytes))).new
      @file      = nil.as(File?)

      if p = @path
        if File.exists?(p)
          open_existing(p)
        else
          create_new(p)
        end
      end
    end

    # Stage a page write into the current (dirty) transaction.
    def write_page(page_no : UInt32, data : Bytes) : Nil
      copy = Bytes.new(PAGE_SIZE)
      data.copy_to(copy)
      @dirty[page_no] = copy
    end

    # Read the most-recent version of a page: dirty > committed > nil (miss → caller reads main file).
    def read_page(page_no : UInt32) : Bytes?
      @dirty[page_no]? || @committed[page_no]?
    end

    # Read only from committed frames, skipping dirty (for concurrent-reader isolation).
    def read_committed(page_no : UInt32) : Bytes?
      @committed[page_no]?
    end

    # Flush dirty frames to disk and promote to committed.
    # If @path is nil (in-memory) there is no disk I/O.
    def commit : Nil
      unless @dirty.empty?
        if f = @file
          # Write ALL dirty frames with flags=0
          @dirty.each do |page_no, data|
            write_frame(f, page_no, 0_u32, data)
          end
          # Write a commit sentinel frame with page_no=0
          sentinel = Bytes.new(PAGE_SIZE)
          write_frame(f, 0_u32, WAL_FRAME_COMMIT, sentinel)
          f.flush
          LibC.fdatasync(f.fd)
        end
        # Promote ALL dirty pages to committed
        @dirty.each { |k, v| @committed[k] = v }
        @dirty.clear
      end
    end

    # Discard all dirty (uncommitted) writes.
    def rollback : Nil
      @dirty.clear
    end

    # ── Savepoint support ──────────────────────────────────────

    def push_savepoint(name : String) : Nil
      snap = Hash(UInt32, Bytes).new
      @dirty.each { |k, v| snap[k] = v.dup }
      @savepoints << {name, snap}
    end

    def pop_savepoint(name : String) : Nil
      idx = @savepoints.rindex { |n, _| n == name }
      return unless idx
      _, snap = @savepoints[idx]
      @dirty = snap
      @savepoints = @savepoints[0...idx]
    end

    def release_savepoint(name : String) : Nil
      @savepoints.reject! { |n, _| n == name }
    end

    # Apply all committed frames to the main DB file and truncate the WAL.
    # After checkpoint committed is cleared.
    def checkpoint(db_file : File, page_count : UInt32) : Nil
      @committed.each do |page_no, data|
        offset = DB_HEADER_SIZE.to_i64 + (page_no - 1).to_i64 * PAGE_SIZE.to_i64
        db_file.seek(offset)
        db_file.write(data)
      end
      db_file.flush
      db_file.fsync
      @committed.clear

      if f = @file
        f.truncate(WAL_HEADER_SIZE.to_i64)
        f.seek(0)
        write_wal_header(f)
        f.flush
        f.fsync
      end
    end

    def close : Nil
      @file.try &.close
      @file = nil
    end

    private def create_new(path : String) : Nil
      f = File.open(path, "w+b")
      write_wal_header(f)
      f.flush
      @file = f
    end

    private def open_existing(path : String) : Nil
      f = File.open(path, "r+b")
      @file = f

      return if f.size < WAL_HEADER_SIZE

      magic = Bytes.new(8)
      f.read_fully?(magic)
      return unless String.new(magic) == WAL_MAGIC

      replay(f)
    end

    # Replay committed frames from an existing WAL into @committed.
    private def replay(f : File) : Nil
      f.seek(WAL_HEADER_SIZE.to_i64)
      pending = Hash(UInt32, Bytes).new

      loop do
        header = Bytes.new(8)
        break unless f.read_fully?(header)

        page_no = IO::ByteFormat::LittleEndian.decode(UInt32, header[0, 4])
        flags   = IO::ByteFormat::LittleEndian.decode(UInt32, header[4, 4])

        data = Bytes.new(PAGE_SIZE)
        break unless f.read_fully?(data)

        if page_no == 0 && (flags & WAL_FRAME_COMMIT) != 0
          # Commit sentinel: promote all pending frames
          pending.each { |k, v| @committed[k] = v }
          pending.clear
        else
          pending[page_no] = data
        end
      end
      # Frames not followed by a commit sentinel are discarded
    end

    private def write_wal_header(f : File) : Nil
      f.seek(0)
      f.write(DB_MAGIC.to_slice)  # reuse constant for magic template
      # Actually write WAL_MAGIC
      f.seek(0)
      f.write(WAL_MAGIC.to_slice)
      ver_buf = Bytes.new(4)
      IO::ByteFormat::LittleEndian.encode(DB_VERSION, ver_buf)
      f.write(ver_buf)
      f.write(Bytes.new(WAL_HEADER_SIZE.to_i - 12))  # reserved
    end

    private def write_frame(f : File, page_no : UInt32, flags : UInt32, data : Bytes) : Nil
      header = Bytes.new(8)
      IO::ByteFormat::LittleEndian.encode(page_no, header[0, 4])
      IO::ByteFormat::LittleEndian.encode(flags,   header[4, 4])
      f.seek(0, IO::Seek::End)
      f.write(header)
      f.write(data[0, PAGE_SIZE])
    end
  end
end
