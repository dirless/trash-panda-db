require "./constants"
require "./pager"
require "./page_layout"

module TrashPandaDB::Storage
  class BTree
    getter root_page : UInt32

    def initialize(@pager : Pager, @root_page : UInt32, @committed_only : Bool = false)
    end

    private def read_page(page_no : UInt32) : Bytes
      @committed_only ? @pager.read_page_committed(page_no) : @pager.read_page(page_no)
    end

    def self.create(pager : Pager) : UInt32
      page_no = pager.allocate_page
      page = Bytes.new(PAGE_SIZE.to_i)
      PageLayout.init_leaf(page)
      pager.write_page(page_no, page)
      page_no
    end

    # ── Public API ────────────────────────────────────────────────────

    def insert(key : Bytes, value : Bytes) : Nil
      result = insert_recursive(@root_page, key, value)
      if result
        promote_key, new_right_page = result
        new_root_no = @pager.allocate_page
        new_root = Bytes.new(PAGE_SIZE.to_i)
        PageLayout.init_internal(new_root, new_right_page)
        cell_offset = PAGE_SIZE.to_i - PageLayout.internal_cell_byte_size(promote_key)
        PageLayout.write_internal_cell(new_root, cell_offset, @root_page, promote_key)
        PageLayout.internal_set_free_end(new_root, cell_offset.to_u16)
        PageLayout.internal_set_cell_count(new_root, 1_u16)
        PageLayout.set_cell_ptr(new_root, 0, cell_offset.to_u16)
        @pager.write_page(new_root_no, new_root)
        @root_page = new_root_no
      end
    end

    def search(key : Bytes) : Bytes?
      search_page(@root_page, key)
    end

    def scan(& : Bytes, Bytes -> Nil) : Nil
      leaf_no = leftmost_leaf(@root_page)
      while leaf_no != 0
        page = read_page(leaf_no)
        cc = PageLayout.leaf_cell_count(page).to_i
        cc.times do |i|
          k, v = PageLayout.read_leaf_cell(page, PageLayout.cell_ptr(page, i).to_i)
          yield k, v
        end
        leaf_no = PageLayout.leaf_next(page)
      end
    end

    def delete(key : Bytes) : Nil
      delete_from_leaf(@root_page, key)
    end

    def update(key : Bytes, value : Bytes) : Nil
      delete(key)
      insert(key, value)
    end

    # ── Private: Search ───────────────────────────────────────────────

    private def search_page(page_no : UInt32, key : Bytes) : Bytes?
      page = read_page(page_no)
      case page[0]
      when BTREE_PAGE_LEAF
        search_leaf(page, key)
      when BTREE_PAGE_INTERNAL
        child_no = find_child(page, key)
        search_page(child_no, key)
      else
        nil
      end
    end

    private def search_leaf(page : Bytes, key : Bytes) : Bytes?
      cc = PageLayout.leaf_cell_count(page).to_i
      lo, hi = 0, cc - 1
      while lo <= hi
        mid = (lo + hi) // 2
        k, v = PageLayout.read_leaf_cell(page, PageLayout.cell_ptr(page, mid).to_i)
        cmp = key <=> k
        if cmp == 0
          result = Bytes.new(v.size)
          v.copy_to(result)
          return result
        elsif cmp < 0
          hi = mid - 1
        else
          lo = mid + 1
        end
      end
      nil
    end

    private def find_child(page : Bytes, key : Bytes) : UInt32
      cc = PageLayout.internal_cell_count(page).to_i
      cc.times do |i|
        left_child, k = PageLayout.read_internal_cell(page, PageLayout.cell_ptr(page, i).to_i)
        return left_child if (key <=> k) < 0
      end
      PageLayout.internal_rightmost(page)
    end

    # ── Private: Leftmost leaf ──────────────────────────────────────

    private def leftmost_leaf(page_no : UInt32) : UInt32
      page = read_page(page_no)
      case page[0]
      when BTREE_PAGE_LEAF
        page_no
      when BTREE_PAGE_INTERNAL
        if PageLayout.internal_cell_count(page) == 0
          PageLayout.internal_rightmost(page)
        else
          left_child, _ = PageLayout.read_internal_cell(page, PageLayout.cell_ptr(page, 0).to_i)
          leftmost_leaf(left_child)
        end
      else
        0_u32
      end
    end

    # ── Private: Delete ─────────────────────────────────────────────

    private def delete_from_leaf(page_no : UInt32, key : Bytes) : Nil
      page = read_page(page_no)
      case page[0]
      when BTREE_PAGE_LEAF
        cc = PageLayout.leaf_cell_count(page).to_i
        cc.times do |i|
          k, _ = PageLayout.read_leaf_cell(page, PageLayout.cell_ptr(page, i).to_i)
          if k == key
            PageLayout.leaf_remove_at(page, i)
            @pager.write_page(page_no, page)
            return
          end
        end
      when BTREE_PAGE_INTERNAL
        child_no = find_child(page, key)
        delete_from_leaf(child_no, key)
      end
    end

    # ── Private: Insert with splits ─────────────────────────────────
    # Returns nil if no split occurred.
    # Returns {promoted_key, new_right_page_no} if this page was split.
    private def insert_recursive(page_no : UInt32, key : Bytes, value : Bytes) : Tuple(Bytes, UInt32)?
      page = read_page(page_no)
      case page[0]
      when BTREE_PAGE_LEAF
        insert_into_leaf(page_no, page, key, value)
      when BTREE_PAGE_INTERNAL
        child_no = find_child(page, key)
        result = insert_recursive(child_no, key, value)
        return nil unless result

        promoted_key, new_right = result
        insert_into_internal(page_no, page, promoted_key, new_right)
      else
        nil
      end
    end

    private def insert_into_leaf(page_no : UInt32, page : Bytes, key : Bytes, value : Bytes) : Tuple(Bytes, UInt32)?
      cell_size = PageLayout.leaf_cell_byte_size(key, value)

      if PageLayout.leaf_has_room?(page, cell_size)
        fe = PageLayout.leaf_free_end(page).to_i
        fe = PAGE_SIZE.to_i if fe == 0
        new_fe = fe - cell_size
        PageLayout.write_leaf_cell(page, new_fe, key, value)
        PageLayout.leaf_sorted_insert(page, key, new_fe.to_u16)
        PageLayout.leaf_set_cell_count(page, (PageLayout.leaf_cell_count(page) + 1_u16))
        PageLayout.leaf_set_free_end(page, new_fe.to_u16)
        @pager.write_page(page_no, page)
        return nil
      end

      split_leaf(page_no, page, key, value)
    end

    # Split a full leaf page. Returns {first_key_of_right_half, new_right_page_no}.
    private def split_leaf(page_no : UInt32, page : Bytes, new_key : Bytes, new_value : Bytes) : Tuple(Bytes, UInt32)
      cc = PageLayout.leaf_cell_count(page).to_i
      cells = Array(Tuple(Bytes, Bytes)).new(cc + 1)
      cc.times do |i|
        k, v = PageLayout.read_leaf_cell(page, PageLayout.cell_ptr(page, i).to_i)
        cells << {k.clone, v.clone}
      end

      # Insert new cell in sorted position
      pos = cells.size
      cells.each_with_index do |(k, _), idx|
        if (new_key <=> k) < 0
          pos = idx
          break
        end
      end
      cells.insert(pos, {new_key, new_value})

      # Split at midpoint so each half fits
      mid = cells.size // 2
      left_cells  = cells[0...mid]
      right_cells = cells[mid..]

      # Rebuild left page (reuse page_no)
      new_left = Bytes.new(PAGE_SIZE.to_i)
      PageLayout.init_leaf(new_left, PageLayout.leaf_prev(page), 0_u32)
      write_cells_to_leaf(new_left, left_cells)
      @pager.write_page(page_no, new_left)

      # Allocate right page
      right_page_no = @pager.allocate_page
      new_right = Bytes.new(PAGE_SIZE.to_i)
      PageLayout.init_leaf(new_right, page_no, PageLayout.leaf_next(page))
      write_cells_to_leaf(new_right, right_cells)
      @pager.write_page(right_page_no, new_right)

      # Fix prev pointer of the page that was originally next to our page
      if (orig_next = PageLayout.leaf_next(page)) != 0
        orig_next_page = read_page(orig_next)
        PageLayout.leaf_set_prev(orig_next_page, right_page_no)
        @pager.write_page(orig_next, orig_next_page)
      end

      # Update left page's next pointer
      PageLayout.leaf_set_next(new_left, right_page_no)
      @pager.write_page(page_no, new_left)

      # The promoted key is the first key of the right page
      promoted_key = right_cells.first[0]
      {promoted_key, right_page_no}
    end

    private def write_cells_to_leaf(page : Bytes, cells : Array(Tuple(Bytes, Bytes))) : Nil
      fe = PAGE_SIZE.to_i
      cells.each_with_index do |(k, v), i|
        cell_size = PageLayout.leaf_cell_byte_size(k, v)
        fe -= cell_size
        raise "Page overflow in leaf: fe=#{fe}, cell_size=#{cell_size}" if fe < 0
        PageLayout.write_leaf_cell(page, fe, k, v)
        PageLayout.set_cell_ptr(page, i, fe.to_u16)
      end
      PageLayout.leaf_set_cell_count(page, cells.size.to_u16)
      PageLayout.leaf_set_free_end(page, fe.to_u16)
    end

    private def insert_into_internal(page_no : UInt32, page : Bytes, key : Bytes, right_child : UInt32) : Tuple(Bytes, UInt32)?
      if PageLayout.internal_has_room?(page, key.size)
        fe = PageLayout.internal_free_end(page).to_i
        fe = PAGE_SIZE.to_i if fe == 0
        cell_size = PageLayout.internal_cell_byte_size(key)
        new_fe = fe - cell_size
        insert_into_internal_page(page, page_no, key, right_child, new_fe)
        nil
      else
        split_internal(page_no, page, key, right_child)
      end
    end

    private def insert_into_internal_page(page : Bytes, page_no : UInt32, key : Bytes, right_child : UInt32, cell_offset : Int32) : Nil
      cc = PageLayout.internal_cell_count(page).to_i
      pos = cc
      cc.times do |i|
        _, k = PageLayout.read_internal_cell(page, PageLayout.cell_ptr(page, i).to_i)
        if (key <=> k) < 0
          pos = i
          break
        end
      end

      left_child_for_new = if pos < cc
        existing_offset = PageLayout.cell_ptr(page, pos).to_i
        old_left, _ = PageLayout.read_internal_cell(page, existing_offset)
        IO::ByteFormat::LittleEndian.encode(right_child, page[existing_offset, 4])
        old_left
      else
        old_rightmost = PageLayout.internal_rightmost(page)
        PageLayout.internal_set_rightmost(page, right_child)
        old_rightmost
      end

      PageLayout.write_internal_cell(page, cell_offset, left_child_for_new, key)

      (cc - 1).downto(pos) do |i|
        PageLayout.set_cell_ptr(page, i + 1, PageLayout.cell_ptr(page, i))
      end
      PageLayout.set_cell_ptr(page, pos, cell_offset.to_u16)
      PageLayout.internal_set_cell_count(page, (cc + 1).to_u16)
      PageLayout.internal_set_free_end(page, cell_offset.to_u16)
      @pager.write_page(page_no, page)
    end

    # Split a full internal page. Returns {promoted_key, new_right_page_no}.
    private def split_internal(page_no : UInt32, page : Bytes, new_key : Bytes, new_right_child : UInt32) : Tuple(Bytes, UInt32)
      cc = PageLayout.internal_cell_count(page).to_i
      cells = Array(Tuple(UInt32, Bytes)).new(cc)
      cc.times do |i|
        left, k = PageLayout.read_internal_cell(page, PageLayout.cell_ptr(page, i).to_i)
        cells << {left, k.clone}
      end
      rightmost = PageLayout.internal_rightmost(page)

      # Insert new cell in sorted order
      pos = cells.size
      cells.each_with_index do |(_, k), idx|
        if (new_key <=> k) < 0
          pos = idx
          break
        end
      end

      if pos < cells.size
        old_left = cells[pos][0]
        cells[pos] = {new_right_child, cells[pos][1]}
        cells.insert(pos, {old_left, new_key})
      else
        cells << {rightmost, new_key}
        rightmost = new_right_child
      end

      mid = cells.size // 2
      promoted_left, promoted_key = cells[mid]
      left_cells  = cells[0...mid]
      right_cells = cells[(mid + 1)..]

      new_left = Bytes.new(PAGE_SIZE.to_i)
      PageLayout.init_internal(new_left, promoted_left)
      write_cells_to_internal(new_left, left_cells)
      @pager.write_page(page_no, new_left)

      right_page_no = @pager.allocate_page
      new_right = Bytes.new(PAGE_SIZE.to_i)
      PageLayout.init_internal(new_right, rightmost)
      write_cells_to_internal(new_right, right_cells)
      @pager.write_page(right_page_no, new_right)

      {promoted_key, right_page_no}
    end

    private def write_cells_to_internal(page : Bytes, cells : Array(Tuple(UInt32, Bytes))) : Nil
      fe = PAGE_SIZE.to_i
      cells.each_with_index do |(left, k), i|
        cell_size = PageLayout.internal_cell_byte_size(k)
        fe -= cell_size
        raise "Page overflow in internal: fe=#{fe}" if fe < 0
        PageLayout.write_internal_cell(page, fe, left, k)
        PageLayout.set_cell_ptr(page, i, fe.to_u16)
      end
      PageLayout.internal_set_cell_count(page, cells.size.to_u16)
      PageLayout.internal_set_free_end(page, fe.to_u16)
    end
  end
end