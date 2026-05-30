require "./constants"

module TrashPandaDB::Storage
  # ── Leaf page layout ────────────────────────────────────────────────────────
  #
  #  [0]      type       : UInt8  = BTREE_PAGE_LEAF
  #  [1-2]    cell_count : UInt16 LE
  #  [3-6]    prev_leaf  : UInt32 LE  (0 = none)
  #  [7-10]   next_leaf  : UInt32 LE  (0 = none)
  #  [11-12]  free_end   : UInt16 LE  (offset of lowest cell byte; PAGE_SIZE when empty)
  #  [13-15]  reserved
  #  [16 ..]  cell pointer array: cell_count × UInt16 offsets (sorted by key)
  #  [.. end] cell content packed from end of page toward start
  #
  # Each cell in a leaf page (inline value):
  #  key_size : UInt16 LE
  #  val_size : UInt32 LE   (bit 31 = overflow flag; bits 30..0 = value byte count)
  #  key      : Bytes[key_size]
  #  val      : Bytes[val_size & ~OVERFLOW_FLAG]
  #
  # Each cell in a leaf page (overflow value, bit 31 of val_size is set):
  #  key_size   : UInt16 LE
  #  val_size   : UInt32 LE   (bit 31 = 1; bits 30..0 = actual value byte count)
  #  key        : Bytes[key_size]
  #  first_page : UInt32 LE  (first overflow page number, 4 bytes)
  #
  # ── Internal page layout ────
  #
  #  [0]      type            : UInt8  = BTREE_PAGE_INTERNAL
  #  [1-2]    cell_count      : UInt16 LE
  #  [3-6]    rightmost_child : UInt32 LE  (page# of rightmost child)
  #  [7-8]    free_end        : UInt16 LE
  #  [9-15]   reserved
  #  [16 ..]  cell pointer array
  #  [.. end] cell content
  #
  # Each cell in an internal page:
  #  left_child : UInt32 LE   (page# of child to the left of this key)
  #  key_size   : UInt16 LE
  #  key        : Bytes[key_size]

  module PageLayout
    LE = IO::ByteFormat::LittleEndian

    # ── Leaf header accessors ─────────────────────────────────────────────

    def self.leaf_cell_count(page : Bytes) : UInt16
      LE.decode(UInt16, page[1, 2])
    end

    def self.leaf_set_cell_count(page : Bytes, n : UInt16) : Nil
      LE.encode(n, page[1, 2])
    end

    def self.leaf_prev(page : Bytes) : UInt32
      LE.decode(UInt32, page[3, 4])
    end

    def self.leaf_set_prev(page : Bytes, v : UInt32) : Nil
      LE.encode(v, page[3, 4])
    end

    def self.leaf_next(page : Bytes) : UInt32
      LE.decode(UInt32, page[7, 4])
    end

    def self.leaf_set_next(page : Bytes, v : UInt32) : Nil
      LE.encode(v, page[7, 4])
    end

    def self.leaf_free_end(page : Bytes) : UInt16
      LE.decode(UInt16, page[11, 2])
    end

    def self.leaf_set_free_end(page : Bytes, v : UInt16) : Nil
      LE.encode(v, page[11, 2])
    end

    # ── Internal header accessors ─────────────────────────────────────────────

    def self.internal_cell_count(page : Bytes) : UInt16
      LE.decode(UInt16, page[1, 2])
    end

    def self.internal_set_cell_count(page : Bytes, n : UInt16) : Nil
      LE.encode(n, page[1, 2])
    end

    def self.internal_rightmost(page : Bytes) : UInt32
      LE.decode(UInt32, page[3, 4])
    end

    def self.internal_set_rightmost(page : Bytes, v : UInt32) : Nil
      LE.encode(v, page[3, 4])
    end

    def self.internal_free_end(page : Bytes) : UInt16
      LE.decode(UInt16, page[7, 2])
    end

    def self.internal_set_free_end(page : Bytes, v : UInt16) : Nil
      LE.encode(v, page[7, 2])
    end

    # ── Cell pointer array ────────────────────────────────────────────────────

    # Offset of the i-th cell pointer in the pointer array
    def self.cell_ptr_offset(i : Int32) : Int32
      16 + i * 2
    end

    # Value of the i-th cell pointer (offset from start of page)
    def self.cell_ptr(page : Bytes, i : Int32) : UInt16
      LE.decode(UInt16, page[cell_ptr_offset(i), 2])
    end

    def self.set_cell_ptr(page : Bytes, i : Int32, offset : UInt16) : Nil
      LE.encode(offset, page[cell_ptr_offset(i), 2])
    end

    # Space used by the pointer array
    def self.ptr_array_bytes(cell_count : Int32) : Int32
      16 + cell_count * 2
    end

    # ── Free space check ─────────────────────────────────────────────────────

    # Returns bytes of free space available for a new cell + its pointer
    def self.free_space(page : Bytes, cell_count : Int32, free_end : UInt16) : Int32
      content_start = ptr_array_bytes(cell_count)
      free_end.to_i - content_start
    end

    # Returns true if the page has enough room for a cell of the given content size.
    # content_size = key_size + val_size + 6 (leaf) or key_size + 6 (internal)
    def self.leaf_has_room?(page : Bytes, content_size : Int32) : Bool
      cc = leaf_cell_count(page).to_i
      fe = leaf_free_end(page).to_i
      available = (fe == 0 ? PAGE_SIZE.to_i : fe) - ptr_array_bytes(cc)
      available >= content_size + 2  # +2 for new pointer
    end

    def self.internal_has_room?(page : Bytes, key_size : Int32) : Bool
      cc = internal_cell_count(page).to_i
      fe = internal_free_end(page).to_i
      available = (fe == 0 ? PAGE_SIZE.to_i : fe) - ptr_array_bytes(cc)
      available >= key_size + 6 + 2  # left_child(4)+key_size(2)+key + pointer
    end

    # ── Leaf cell read/write ──────────────────────────────────────────────

    # Read cell at the given page offset. Returns {key, val_or_ptr}.
    # For inline cells val_or_ptr is the actual value bytes.
    # For overflow cells val_or_ptr is the 4-byte first overflow page number
    # (little-endian UInt32); use leaf_cell_is_overflow? to distinguish.
    def self.read_leaf_cell(page : Bytes, offset : Int32) : Tuple(Bytes, Bytes)
      key_size     = LE.decode(UInt16, page[offset, 2]).to_i
      raw_val_size = LE.decode(UInt32, page[offset + 2, 4])
      base = offset + 6
      key  = page[base, key_size]
      val  = if (raw_val_size & OVERFLOW_FLAG) != 0
               page[base + key_size, 4]  # 4-byte overflow page pointer
             else
               page[base + key_size, raw_val_size.to_i]
             end
      {key, val}
    end

    # Write an inline leaf cell at the given page offset.
    def self.write_leaf_cell(page : Bytes, offset : Int32, key : Bytes, val : Bytes) : Nil
      LE.encode(key.size.to_u16, page[offset, 2])
      LE.encode(val.size.to_u32, page[offset + 2, 4])
      key.copy_to(page[offset + 6, key.size])
      val.copy_to(page[offset + 6 + key.size, val.size])
    end

    # Write an overflow leaf cell. Stores a pointer to first_overflow_page instead of
    # the value; actual_val_size is stored in bits 30..0 of the val_size field.
    def self.write_leaf_cell_overflow(page : Bytes, offset : Int32, key : Bytes,
                                      first_overflow_page : UInt32, actual_val_size : Int32) : Nil
      LE.encode(key.size.to_u16, page[offset, 2])
      LE.encode(OVERFLOW_FLAG | actual_val_size.to_u32, page[offset + 2, 4])
      key.copy_to(page[offset + 6, key.size])
      LE.encode(first_overflow_page, page[offset + 6 + key.size, 4])
    end

    def self.leaf_cell_byte_size(key : Bytes, val : Bytes) : Int32
      6 + key.size + val.size
    end

    # ── Internal cell read/write ──────────────────────────────────────────

    # Returns {left_child_page, key}
    def self.read_internal_cell(page : Bytes, offset : Int32) : Tuple(UInt32, Bytes)
      left_child = LE.decode(UInt32, page[offset, 4])
      key_size   = LE.decode(UInt16, page[offset + 4, 2]).to_i
      key        = page[offset + 6, key_size]
      {left_child, key}
    end

    def self.write_internal_cell(page : Bytes, offset : Int32, left_child : UInt32, key : Bytes) : Nil
      LE.encode(left_child, page[offset, 4])
      LE.encode(key.size.to_u16, page[offset + 4, 2])
      key.copy_to(page[offset + 6, key.size])
    end

    def self.internal_cell_byte_size(key : Bytes) : Int32
      6 + key.size
    end

    # ── Sorted insert into cell pointer array ─────────────────────────────────
    #
    # Inserts new_cell_offset at the sorted position for new_key in the
    # cell pointer array (binary search by key comparison using read_leaf_cell).
    # Shifts existing pointers right.  Assumes page has room.
    # Returns the index at which the pointer was inserted.
    def self.leaf_sorted_insert(page : Bytes, new_key : Bytes, new_cell_offset : UInt16) : Int32
      cc = leaf_cell_count(page).to_i
      # Binary search for insertion point
      lo = 0
      hi = cc
      while lo < hi
        mid = (lo + hi) // 2
        existing_key, _ = read_leaf_cell(page, cell_ptr(page, mid).to_i)
        if new_key <=> existing_key < 0
          hi = mid
        else
          lo = mid + 1
        end
      end
      # lo is insertion index; shift pointers right
      (cc - 1).downto(lo) do |i|
        ptr = cell_ptr(page, i)
        set_cell_ptr(page, i + 1, ptr)
      end
      set_cell_ptr(page, lo, new_cell_offset)
      lo
    end

    # ── Remove cell from leaf ─────────────────────────────────────────────────
    # Removes the cell pointer at index i, shifts remaining pointers left,
    # and compacts cell content so free_end accurately reflects available space.
    def self.leaf_remove_at(page : Bytes, i : Int32) : Bytes
      cc = leaf_cell_count(page).to_i
      key, _ = read_leaf_cell(page, cell_ptr(page, i).to_i)
      (i + 1...cc).each do |j|
        set_cell_ptr(page, j - 1, cell_ptr(page, j))
      end
      new_cc = cc - 1
      leaf_set_cell_count(page, new_cc.to_u16)
      compact_leaf(page, new_cc)
      key
    end

    # Repacks all remaining cells to the end of the page and updates free_end.
    # Reclaims the gap left by the removed cell so subsequent leaf_has_room?
    # checks reflect the true available space.
    private def self.compact_leaf(page : Bytes, cc : Int32) : Nil
      if cc == 0
        leaf_set_free_end(page, PAGE_SIZE.to_u16)
        return
      end
      # Snapshot all remaining cells before overwriting — pointers and content
      # may overlap once we start repacking from the end.
      cells = Array(Tuple(Bytes, Bytes, Bool, Int32)).new(cc)
      cc.times do |i|
        offset = cell_ptr(page, i).to_i
        k, v   = read_leaf_cell(page, offset)
        is_ov  = leaf_cell_is_overflow?(page, offset)
        act_sz = is_ov ? leaf_cell_overflow_actual_size(page, offset) : 0
        cells << {k.dup, v.dup, is_ov, act_sz}
      end
      # Rewrite cells packed from the end of the page.
      fe = PAGE_SIZE.to_i
      cells.each_with_index do |(k, v, is_ov, act_sz), idx|
        if is_ov
          fe -= leaf_cell_overflow_byte_size(k)
          write_leaf_cell_overflow(page, fe, k, LE.decode(UInt32, v), act_sz)
        else
          fe -= leaf_cell_byte_size(k, v)
          write_leaf_cell(page, fe, k, v)
        end
        set_cell_ptr(page, idx, fe.to_u16)
      end
      leaf_set_free_end(page, fe.to_u16)
    end

    # ── Overflow page accessors ───────────────────────────────────────────────

    def self.overflow_next(page : Bytes) : UInt32
      LE.decode(UInt32, page[1, 4])
    end

    def self.overflow_set_next(page : Bytes, v : UInt32) : Nil
      LE.encode(v, page[1, 4])
    end

    # Slice covering the data region of an overflow page (bytes 8..end).
    def self.overflow_data(page : Bytes) : Bytes
      page[OVERFLOW_HDR_SIZE.to_i, OVERFLOW_DATA_SIZE.to_i]
    end

    # ── Overflow cell detection helpers ──────────────────────────────────────

    def self.leaf_cell_is_overflow?(page : Bytes, offset : Int32) : Bool
      (LE.decode(UInt32, page[offset + 2, 4]) & OVERFLOW_FLAG) != 0
    end

    # Returns the first overflow page number. Call only when leaf_cell_is_overflow?.
    def self.leaf_cell_overflow_page_no(page : Bytes, offset : Int32) : UInt32
      key_size = LE.decode(UInt16, page[offset, 2]).to_i
      LE.decode(UInt32, page[offset + 6 + key_size, 4])
    end

    # Returns the actual (uncompressed) value byte count. Call only when leaf_cell_is_overflow?.
    def self.leaf_cell_overflow_actual_size(page : Bytes, offset : Int32) : Int32
      (LE.decode(UInt32, page[offset + 2, 4]) & ~OVERFLOW_FLAG).to_i
    end

    # True when a value is too large to store inline in any leaf page.
    def self.needs_overflow?(key : Bytes, val : Bytes) : Bool
      6 + key.size + val.size > PAGE_SIZE.to_i - LEAF_HEADER_SIZE.to_i - CELL_PTR_SIZE.to_i
    end

    # Inline byte size for an overflow cell (stores a 4-byte page pointer, not the value).
    def self.leaf_cell_overflow_byte_size(key : Bytes) : Int32
      6 + key.size + 4
    end

    # ── Initialise blank pages ├────────────────────────────────────────────────

    def self.init_leaf(page : Bytes, prev : UInt32 = 0_u32, nxt : UInt32 = 0_u32) : Nil
      page.fill(0_u8)
      page[0] = BTREE_PAGE_LEAF
      leaf_set_cell_count(page, 0_u16)
      leaf_set_prev(page, prev)
      leaf_set_next(page, nxt)
      leaf_set_free_end(page, PAGE_SIZE.to_u16)
    end

    def self.init_internal(page : Bytes, rightmost : UInt32 = 0_u32) : Nil
      page.fill(0_u8)
      page[0] = BTREE_PAGE_INTERNAL
      internal_set_cell_count(page, 0_u16)
      internal_set_rightmost(page, rightmost)
      internal_set_free_end(page, PAGE_SIZE.to_u16)
    end

    def self.init_overflow(page : Bytes, next_page : UInt32 = 0_u32) : Nil
      page.fill(0_u8)
      page[0] = BTREE_PAGE_OVERFLOW
      overflow_set_next(page, next_page)
    end
  end
end