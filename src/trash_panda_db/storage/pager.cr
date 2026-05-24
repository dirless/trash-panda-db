require "./constants"
require "./wal"

module TrashPandaDB::Storage
  # Manages page I/O, the WAL, and the in-memory page cache.
  #
  # Page numbers are 1-based.  Page 0 is reserved / invalid.
  # Layout on disk:
  #   [DB header 64 bytes][page 1][page 2]…
  #
  # Read priority: dirty WAL > committed WAL > page cache > disk > zeroed new page
  class Pager
    getter page_count : UInt32
    getter wal : WAL
    getter path : String?

    def initialize(path : String | Nil)
      @path           = path
      @page_count     = 1_u32  # page 1 is reserved for the catalog
      @free_list_head = 0_u32
      @cache          = Hash(UInt32, Bytes).new
      @closed         = false

      if p = path
        @wal = WAL.new("#{p}-wal")
        if File.exists?(p)
          @file = File.open(p, "r+b")
          load_header
        else
          @file = File.open(p, "w+b")
          write_header
        end
      else
        @wal  = WAL.new(nil)
        @file = nil.as(File?)
      end
    end

    # Return a copy of page data. Allocates the page if page_no > @page_count.
    def read_page(page_no : UInt32) : Bytes
      raise ArgumentError.new("invalid page_no 0") if page_no == 0

      if cached = @wal.read_page(page_no)
        copy = Bytes.new(PAGE_SIZE)
        cached.copy_to(copy)
        return copy
      end

      if cached = @cache[page_no]?
        copy = Bytes.new(PAGE_SIZE)
        cached.copy_to(copy)
        return copy
      end

      if page_no <= @page_count
        if f = @file
          buf = Bytes.new(PAGE_SIZE)
          f.seek(page_offset(page_no))
          f.read_fully?(buf)
          @cache[page_no] = buf
          copy = Bytes.new(PAGE_SIZE)
          buf.copy_to(copy)
          return copy
        end
      end

      # New / in-memory page — return zeroed buffer.
      Bytes.new(PAGE_SIZE)
    end

    # Read a page skipping dirty WAL — used by concurrent readers during a transaction.
    def read_page_committed(page_no : UInt32) : Bytes
      raise ArgumentError.new("invalid page_no 0") if page_no == 0

      if cached = @wal.read_committed(page_no)
        copy = Bytes.new(PAGE_SIZE)
        cached.copy_to(copy)
        return copy
      end

      if cached = @cache[page_no]?
        copy = Bytes.new(PAGE_SIZE)
        cached.copy_to(copy)
        return copy
      end

      if page_no <= @page_count
        if f = @file
          buf = Bytes.new(PAGE_SIZE)
          f.seek(page_offset(page_no))
          f.read_fully?(buf)
          @cache[page_no] = buf
          copy = Bytes.new(PAGE_SIZE)
          buf.copy_to(copy)
          return copy
        end
      end

      Bytes.new(PAGE_SIZE)
    end

    # Stage a dirty write for page_no. If page_no > @page_count, page_count is extended.
    def write_page(page_no : UInt32, data : Bytes) : Nil
      raise ArgumentError.new("invalid page_no 0") if page_no == 0
      raise ArgumentError.new("data must be #{PAGE_SIZE} bytes") unless data.size == PAGE_SIZE

      @wal.write_page(page_no, data)
      @cache.delete(page_no)
      @page_count = page_no if page_no > @page_count
    end

    # Allocate a new page and return its number.
    # Checks the free list first; if empty, extends page_count.
    def allocate_page : UInt32
      if @free_list_head != 0
        no = @free_list_head
        page = read_page(no)
        @free_list_head = IO::ByteFormat::LittleEndian.decode(UInt32, page[1, 4])
        no
      else
        @page_count += 1
        @page_count
      end
    end

    # Mark a page as free and add it to the free list.
    def free_page(page_no : UInt32) : Nil
      page = Bytes.new(PAGE_SIZE.to_i)
      page[0] = BTREE_PAGE_FREE
      IO::ByteFormat::LittleEndian.encode(@free_list_head, page[1, 4])
      write_page(page_no, page)
      @free_list_head = page_no
    end

    # Commit the current transaction: flush WAL, optionally checkpoint when WAL grows large.
    def commit : Nil
      @wal.commit
      checkpoint if should_checkpoint?
    end

    # Roll back all dirty (uncommitted) writes.
    def rollback : Nil
      @wal.rollback
    end

    # Force WAL → main file and clear the WAL.
    def checkpoint : Nil
      return if @closed
      if f = @file
        ensure_file_capacity(f)
        write_header(f)
        @wal.checkpoint(f, @page_count)
        f.flush
      else
        # In-memory: promote committed pages into local cache and reset WAL state.
        # The WAL has no backing file in this mode so WAL#checkpoint is a no-op on
        # disk; calling it was only leaking an unclosed /dev/null FD.
        @wal.committed.each { |k, v| @cache[k] = v }
        @wal.committed.clear
      end
    end

    def close : Nil
      return if @closed
      @closed = true
      @wal.close
      if f = @file
        f.flush
        f.close
      end
    end

    private def page_offset(page_no : UInt32) : Int64
      DB_HEADER_SIZE.to_i64 + (page_no - 1).to_i64 * PAGE_SIZE.to_i64
    end

    private def load_header : Nil
      f = @file.not_nil!
      return if f.size < DB_HEADER_SIZE

      buf = Bytes.new(DB_HEADER_SIZE)
      f.seek(0)
      f.read_fully?(buf)

      magic = String.new(buf[DB_MAGIC_OFFSET, 8])
      raise "not a TrashPandaDB file (bad magic)" unless magic == DB_MAGIC

      version = IO::ByteFormat::LittleEndian.decode(UInt32, buf[DB_VER_OFFSET, 4])
      if version == DB_VERSION_JSON
        raise "TrashPandaDB file was created with the JSON storage format (v1). " \
              "Delete the file and start fresh, or run: trashpandadb migrate <path>"
      end

      @page_count = IO::ByteFormat::LittleEndian.decode(UInt32, buf[DB_PGCOUNT_OFFSET, 4])
      @page_count = 1_u32 if @page_count < 1  # page 1 is reserved for the catalog
      @free_list_head = IO::ByteFormat::LittleEndian.decode(UInt32, buf[16, 4])

      # Replay WAL on top of header page count.
      # WAL-committed pages may include pages beyond the header's page_count if we
      # crashed between WAL commit and checkpoint.
      @wal.committed.each_key do |k|
        @page_count = k if k > @page_count
      end
    end

    private def write_header(f : File? = @file) : Nil
      return unless f
      buf = Bytes.new(DB_HEADER_SIZE)
      DB_MAGIC.to_slice.copy_to(buf[DB_MAGIC_OFFSET, 8])
      IO::ByteFormat::LittleEndian.encode(DB_VERSION_BTREE, buf[DB_VER_OFFSET, 4])
      IO::ByteFormat::LittleEndian.encode(@page_count,     buf[DB_PGCOUNT_OFFSET, 4])
      IO::ByteFormat::LittleEndian.encode(@free_list_head, buf[16, 4])
      f.seek(0)
      f.write(buf)
      f.flush
    end

    # Extend the file so all allocated pages have space before checkpoint writes them.
    private def ensure_file_capacity(f : File) : Nil
      needed = DB_HEADER_SIZE.to_i64 + @page_count.to_i64 * PAGE_SIZE.to_i64
      if f.size < needed
        f.seek(needed - 1)
        f.write(Bytes.new(1))
      end
    end

    private def should_checkpoint? : Bool
      @file != nil && !@wal.committed.empty?
    end

    def push_savepoint(name : String) : Nil
      @wal.push_savepoint(name)
    end

    def pop_savepoint(name : String) : Nil
      @wal.pop_savepoint(name)
    end

    def release_savepoint(name : String) : Nil
      @wal.release_savepoint(name)
    end
  end
end
