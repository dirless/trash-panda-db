# PLAN.md — Overflow Pages for TrashPandaDB

## Why

The `snapshots` table in the Dirless backend stores one `TEXT` column per tenant holding a gzip+age-encrypted payload. With 1001 users and 75 groups the payload is ~52KB after compression and base64 encoding. This exceeds any reasonable fixed `PAGE_SIZE` for inline storage. The fix is overflow pages: values larger than a threshold are stored in a chain of dedicated overflow pages, with only a 4-byte pointer kept inline in the leaf cell.

---

## Current State (what already exists)

- `BTREE_PAGE_OVERFLOW = 0x03_u8` is already defined in `constants.cr` — the page type is reserved.
- The leaf cell header already has a comment reserving the MSB of `val_size` for an overflow flag: `# val_size : UInt32 LE (MSB = overflow flag, not yet implemented)` (page_layout.cr:18).
- `pager.allocate_page` and `pager.free_page` are already implemented and correct.
- The catalog (catalog.cr) already chains pages for large metadata — use it as a reference for chain traversal patterns.

---

## Overflow Page Format

```
[0]      type           : UInt8   = BTREE_PAGE_OVERFLOW (0x03)
[1-4]    next_page      : UInt32 LE  (page number of next overflow page; 0 = last)
[5-7]    reserved       : 3 bytes (zero)
[8 ..]   data           : PAGE_SIZE - 8 bytes of value content
```

Data capacity per overflow page: `PAGE_SIZE - 8` bytes.

A value of size N requires `ceil(N / (PAGE_SIZE - 8))` overflow pages.

---

## Modified Leaf Cell Format (overflow case)

When the overflow flag is set, the cell stores a pointer instead of the value:

```
key_size    : UInt16 LE               (unchanged)
val_size    : UInt32 LE               (bit 31 = 1; bits 30..0 = actual value byte count)
key         : Bytes[key_size]         (unchanged — key is always inline)
first_page  : UInt32 LE               (page number of first overflow page, 4 bytes)
```

Total inline cell size for an overflow cell: `6 + key_size + 4` bytes. Always tiny.

Non-overflow cells are unchanged. The MSB of `val_size` was previously always 0, so old databases (with inline values only) are still readable by the new code.

---

## Overflow Threshold

Use overflow when the full inline cell would not fit in a completely empty leaf page:

```crystal
OVERFLOW_THRESHOLD = PAGE_SIZE.to_i - LEAF_HEADER_SIZE.to_i - CELL_PTR_SIZE.to_i - 6
# approximately PAGE_SIZE - 18 bytes
# For PAGE_SIZE = 32768: threshold = 32750 bytes
```

If `key.size + val.size > OVERFLOW_THRESHOLD - key.size` — i.e., `6 + key.size + val.size > PAGE_SIZE - LEAF_HEADER_SIZE - CELL_PTR_SIZE` — store the value via overflow.

This threshold ensures: even on a fresh empty page, an overflow cell (pointer = 4 bytes) always fits.

---

## Constants to Add (`constants.cr`)

```crystal
OVERFLOW_FLAG         = 0x80000000_u32   # bit 31 of val_size field
OVERFLOW_MAX_VAL_SIZE = 0x7FFFFFFF_u32   # max value size (31 bits)
OVERFLOW_HDR_SIZE     = 8_u32            # type(1) + next_page(4) + reserved(3)
OVERFLOW_DATA_SIZE    = PAGE_SIZE - OVERFLOW_HDR_SIZE
```

---

## Changes: `page_layout.cr`

### 1. Add overflow page accessors

```crystal
def self.overflow_next(page : Bytes) : UInt32
  LE.decode(UInt32, page[1, 4])
end

def self.overflow_set_next(page : Bytes, v : UInt32) : Nil
  LE.encode(v, page[1, 4])
end

def self.overflow_data(page : Bytes) : Bytes
  page[OVERFLOW_HDR_SIZE.to_i, OVERFLOW_DATA_SIZE.to_i]
end

def self.init_overflow(page : Bytes, next_page : UInt32) : Nil
  page.fill(0)
  page[0] = BTREE_PAGE_OVERFLOW
  overflow_set_next(page, next_page)
end
```

### 2. Add overflow detection helper

```crystal
def self.val_is_overflow?(raw_val_size : UInt32) : Bool
  (raw_val_size & OVERFLOW_FLAG) != 0
end

def self.val_actual_size(raw_val_size : UInt32) : Int32
  (raw_val_size & ~OVERFLOW_FLAG).to_i
end
```

### 3. Modify `read_leaf_cell`

Change the signature to return a flag indicating whether the value is an overflow pointer:

```crystal
# Returns {key, val_or_pointer_bytes, overflow?}
# - overflow? = false: val_or_pointer_bytes is the actual value
# - overflow? = true:  val_or_pointer_bytes is a 4-byte page number (LE UInt32),
#                      and the actual value size is in raw_val_size (callers can
#                      recompute from the 4-byte storage if needed)
def self.read_leaf_cell(page : Bytes, offset : Int32) : Tuple(Bytes, Bytes, Bool)
  key_size    = LE.decode(UInt16, page[offset, 2]).to_i
  raw_val_size = LE.decode(UInt32, page[offset + 2, 4])
  base = offset + 6
  key  = page[base, key_size]
  if val_is_overflow?(raw_val_size)
    ptr = page[base + key_size, 4]   # 4-byte first overflow page number
    {key, ptr, true}
  else
    val = page[base + key_size, raw_val_size.to_i]
    {key, val, false}
  end
end
```

**All existing call sites** use `k, v = PageLayout.read_leaf_cell(...)`. The added Bool needs to be handled:
- Call sites that only use `k` (key): change to `k, _, _ = ...` — no other change.
- Call sites that use `v` (value): must check the overflow flag and follow the chain. These are in `btree.cr` (covered below).

### 4. Modify `write_leaf_cell`

Add an optional `overflow_page_no` parameter:

```crystal
# When overflow_page_no is provided, writes an overflow pointer cell.
# val is ignored in that case; overflow_page_no is the first overflow page.
def self.write_leaf_cell(page : Bytes, offset : Int32, key : Bytes, val : Bytes,
                         overflow_page_no : UInt32? = nil, actual_val_size : Int32 = 0) : Nil
  if op = overflow_page_no
    raw_val_size = (OVERFLOW_FLAG | actual_val_size.to_u32)
    LE.encode(key.size.to_u16,  page[offset, 2])
    LE.encode(raw_val_size,     page[offset + 2, 4])
    key.copy_to(page[offset + 6, key.size])
    LE.encode(op, page[offset + 6 + key.size, 4])
  else
    LE.encode(key.size.to_u16,  page[offset, 2])
    LE.encode(val.size.to_u32,  page[offset + 2, 4])
    key.copy_to(page[offset + 6, key.size])
    val.copy_to(page[offset + 6 + key.size, val.size])
  end
end
```

### 5. Add `leaf_cell_overflow_size`

```crystal
# Size of a leaf cell when the value is stored via overflow (pointer only).
def self.leaf_cell_overflow_size(key : Bytes) : Int32
  6 + key.size + 4   # header + key + 4-byte overflow page pointer
end
```

### 6. Modify `leaf_cell_byte_size`

This is used by `insert_into_leaf` to decide whether to split. After overflow is
introduced, a cell going into the leaf is always an overflow pointer if the value
is large — so `leaf_cell_byte_size` should reflect the size that will actually be
written:

```crystal
def self.leaf_cell_byte_size(key : Bytes, val : Bytes) : Int32
  if needs_overflow?(key, val)
    leaf_cell_overflow_size(key)
  else
    6 + key.size + val.size
  end
end

def self.needs_overflow?(key : Bytes, val : Bytes) : Bool
  6 + key.size + val.size > PAGE_SIZE.to_i - LEAF_HEADER_SIZE.to_i - CELL_PTR_SIZE.to_i
end
```

---

## Changes: `btree.cr`

### 1. Add `write_overflow_chain`

Allocates overflow pages and writes `value` across them. Returns the first page number.

```crystal
private def write_overflow_chain(value : Bytes) : UInt32
  pages_needed = (value.size + OVERFLOW_DATA_SIZE.to_i - 1) // OVERFLOW_DATA_SIZE.to_i
  page_nos = Array(UInt32).new(pages_needed) { @pager.allocate_page }

  pages_needed.times do |i|
    page = Bytes.new(PAGE_SIZE.to_i, 0_u8)
    next_page = (i + 1 < pages_needed) ? page_nos[i + 1] : 0_u32
    PageLayout.init_overflow(page, next_page)

    data_start = i * OVERFLOW_DATA_SIZE.to_i
    data_end   = {data_start + OVERFLOW_DATA_SIZE.to_i, value.size}.min
    chunk      = value[data_start, data_end - data_start]
    chunk.copy_to(page[OVERFLOW_HDR_SIZE.to_i, chunk.size])

    @pager.write_page(page_nos[i], page)
  end

  page_nos[0]
end
```

### 2. Add `read_overflow_chain`

Follows the overflow chain and reassembles the value. `actual_size` is stored in
the leaf cell's `val_size` field (bits 30..0).

```crystal
private def read_overflow_chain(first_page_no : UInt32, actual_size : Int32) : Bytes
  result = Bytes.new(actual_size)
  written = 0
  page_no = first_page_no

  while page_no != 0 && written < actual_size
    page  = read_page(page_no)
    chunk = {OVERFLOW_DATA_SIZE.to_i, actual_size - written}.min
    PageLayout.overflow_data(page)[0, chunk].copy_to(result[written, chunk])
    written += chunk
    page_no = PageLayout.overflow_next(page)
  end

  result
end
```

### 3. Add `free_overflow_chain`

```crystal
private def free_overflow_chain(first_page_no : UInt32) : Nil
  page_no = first_page_no
  while page_no != 0
    page    = read_page(page_no)
    next_no = PageLayout.overflow_next(page)
    @pager.free_page(page_no)
    page_no = next_no
  end
end
```

### 4. Add `read_leaf_cell_value` helper

Resolves overflow transparently. Use this wherever the actual value is needed.

```crystal
private def read_leaf_cell_value(page : Bytes, offset : Int32) : Tuple(Bytes, Bytes)
  key, ptr_or_val, overflow = PageLayout.read_leaf_cell(page, offset)
  if overflow
    # ptr_or_val is 4 bytes: the first overflow page number
    first_page = IO::ByteFormat::LittleEndian.decode(UInt32, ptr_or_val)
    # actual_size is in bits 30..0 of val_size in the cell header
    raw_val_size = IO::ByteFormat::LittleEndian.decode(UInt32, page[offset + 2, 4])
    actual_size  = (raw_val_size & ~PageLayout::OVERFLOW_FLAG).to_i
    {key, read_overflow_chain(first_page, actual_size)}
  else
    {key, ptr_or_val}
  end
end
```

### 5. Modify `insert_into_leaf`

Before writing the cell, check if overflow is needed:

```crystal
private def insert_into_leaf(page_no : UInt32, page : Bytes, key : Bytes, value : Bytes) : Tuple(Bytes, UInt32)?
  raise DuplicateKeyError.new("duplicate key") if leaf_find_slot(page, key)

  if PageLayout.needs_overflow?(key, value)
    # Allocate overflow chain first, then write a tiny pointer cell
    first_page = write_overflow_chain(value)
    overflow_cell_size = PageLayout.leaf_cell_overflow_size(key)
    # A fresh page always has room for a pointer cell; split if page is full of other cells
    if PageLayout.leaf_has_room?(page, overflow_cell_size)
      fe = PageLayout.leaf_free_end(page).to_i
      fe = PAGE_SIZE.to_i if fe == 0
      new_fe = fe - overflow_cell_size
      PageLayout.write_leaf_cell(page, new_fe, key, Bytes.empty,
                                 overflow_page_no: first_page,
                                 actual_val_size: value.size)
      PageLayout.leaf_sorted_insert(page, key, new_fe.to_u16)
      PageLayout.leaf_set_cell_count(page, (PageLayout.leaf_cell_count(page) + 1_u16))
      PageLayout.leaf_set_free_end(page, new_fe.to_u16)
      @pager.write_page(page_no, page)
      return nil
    else
      return split_leaf_overflow(page_no, page, key, first_page, value.size)
    end
  end

  # Original inline path (unchanged)
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
```

The `split_leaf` for the overflow case: `split_leaf_overflow` is the same as `split_leaf` but uses `leaf_cell_overflow_size` for the new cell. Since overflow pointer cells are tiny (`10 + key_size` bytes), they will always fit after the midpoint split. Alternatively, you can factor this into the existing `split_leaf` by passing a pre-computed cell representation.

**Simpler option:** Instead of a separate `split_leaf_overflow`, collect all cells as raw `{key, ptr_or_val, overflow_page_no?, actual_size}` tuples and handle in one split path. Whatever approach keeps the code cleanest.

### 6. Modify `search_leaf`

```crystal
private def search_leaf(page : Bytes, key : Bytes) : Bytes?
  return nil unless slot = leaf_find_slot(page, key)
  _, v = read_leaf_cell_value(page, PageLayout.cell_ptr(page, slot).to_i)
  result = Bytes.new(v.size)
  v.copy_to(result)
  result
end
```

### 7. Modify `scan` and `scan_from`

Replace `PageLayout.read_leaf_cell` calls with `read_leaf_cell_value`:

```crystal
def scan(& : Bytes, Bytes -> Nil) : Nil
  leaf_no = leftmost_leaf(@root_page)
  while leaf_no != 0
    page = read_page(leaf_no)
    cc = PageLayout.leaf_cell_count(page).to_i
    cc.times do |i|
      k, v = read_leaf_cell_value(page, PageLayout.cell_ptr(page, i).to_i)
      yield k, v
    end
    leaf_no = PageLayout.leaf_next(page)
  end
end
```

Same change for `scan_from`.

### 8. Modify `delete_from_leaf`

Free overflow chain before removing the cell from the page:

```crystal
private def delete_from_leaf(page_no : UInt32, key : Bytes) : Nil
  page = read_page(page_no)
  case page[0]
  when BTREE_PAGE_LEAF
    cc = PageLayout.leaf_cell_count(page).to_i
    cc.times do |i|
      k, ptr_or_val, overflow = PageLayout.read_leaf_cell(page, PageLayout.cell_ptr(page, i).to_i)
      if k == key
        if overflow
          first_page = IO::ByteFormat::LittleEndian.decode(UInt32, ptr_or_val)
          free_overflow_chain(first_page)
        end
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
```

### 9. Modify `free_subtree`

Free overflow chains when freeing leaf pages:

```crystal
when BTREE_PAGE_LEAF
  cc = PageLayout.leaf_cell_count(page).to_i
  cc.times do |i|
    _, ptr_or_val, overflow = PageLayout.read_leaf_cell(page, PageLayout.cell_ptr(page, i).to_i)
    if overflow
      first_page = IO::ByteFormat::LittleEndian.decode(UInt32, ptr_or_val)
      free_overflow_chain(first_page)
    end
  end
  @pager.free_page(page_no)
```

### 10. `leaf_find_slot` — no change needed

This method binary-searches by key only. The existing `read_leaf_cell` call ignores the value. With the updated `read_leaf_cell` signature returning a triple, change to `k, _, _ = PageLayout.read_leaf_cell(...)`. No overflow following required.

---

## Call Sites to Update (`btree.cr`)

Every call to `PageLayout.read_leaf_cell` needs the third return value handled:

| Line (approx) | Current | Update to |
|---|---|---|
| `leaf_find_slot` | `k, _ = read_leaf_cell(...)` | `k, _, _ = read_leaf_cell(...)` |
| `search_leaf` | `_, v = read_leaf_cell(...)` | use `read_leaf_cell_value` |
| `scan` | `k, v = read_leaf_cell(...)` | use `read_leaf_cell_value` |
| `scan_from` | `k, v = read_leaf_cell(...)` | use `read_leaf_cell_value` |
| `split_leaf` (cell collection) | `k, v = read_leaf_cell(...)` | `k, ptr_or_val, overflow = read_leaf_cell(...)` — cells stored as raw form (pointer or val) |
| `delete_from_leaf` | `k, _ = read_leaf_cell(...)` | `k, ptr_or_val, overflow = read_leaf_cell(...)` |
| `free_subtree` (leaf case) | none currently | add loop with `read_leaf_cell` to free overflow chains |

---

## Split Logic with Overflow Cells

In `split_leaf`, cells from the existing page are collected and re-sorted. Overflow cells must be preserved as pointers during the split — **the overflow pages themselves do not move**.

When collecting cells:
- Read each cell raw: `k, ptr_or_val, overflow = PageLayout.read_leaf_cell(page, offset)`
- Store as a tagged tuple: `{key, ptr_or_val, overflow, actual_size}` (where `actual_size` only matters when `overflow == true`)

When writing cells back in `write_cells_to_leaf`:
- If `overflow == true`: call `write_leaf_cell(..., overflow_page_no: first_page, actual_val_size: actual_size)` using `leaf_cell_overflow_size(key)` as the cell size
- If `overflow == false`: original path

This requires changing `write_cells_to_leaf` to work with the tagged tuple instead of plain `(Bytes, Bytes)`. The function signature changes from `Array(Tuple(Bytes, Bytes))` to an array of a richer type — introduce a private `struct CellData` or a named tuple for clarity.

---

## Implementation Order

Work in phases so each phase is independently testable:

**Phase 1 — Overflow write + read (no delete, no split of overflow cells)**
1. Add constants to `constants.cr`
2. Add overflow page accessors to `page_layout.cr`
3. Add `needs_overflow?`, `leaf_cell_overflow_size`, modify `leaf_cell_byte_size`
4. Modify `write_leaf_cell` to accept overflow pointer
5. Add `write_overflow_chain` and `read_overflow_chain` to `btree.cr`
6. Add `read_leaf_cell_value` helper
7. Modify `read_leaf_cell` return type → triple
8. Fix all call site signatures (only key needed → ignore extra values)
9. Modify `insert_into_leaf` for overflow case (leaf has room path only)
10. Modify `search_leaf` and `scan`/`scan_from` to use `read_leaf_cell_value`
11. **Test:** insert large value, read it back, scan includes it

**Phase 2 — Delete and free**
1. Modify `delete_from_leaf` to free overflow chain
2. Modify `free_subtree` to free overflow chains on leaf pages
3. **Test:** insert large value, delete it, verify overflow pages are on free list, verify pager page count is consistent

**Phase 3 — Split with overflow cells**
1. Change `split_leaf` cell collection to use tagged tuples
2. Change `write_cells_to_leaf` to handle tagged tuples
3. **Test:** insert many large values (forcing multiple leaf splits), read them all back, scan in order

**Phase 4 — Update (upsert)**
Since `update` = `delete` + `insert`, and both are already handled by Phases 1-3, this should work. Explicit test: upsert same key twice with large values, verify old overflow pages are freed and new ones written.

---

## Test Cases to Add

File: `spec/storage/btree_spec.cr` (follow existing patterns)

```
- insert value of exactly PAGE_SIZE - 8 bytes (single overflow page)
- insert value of PAGE_SIZE * 2 bytes (multi-page chain)
- read back both values, assert equal
- scan includes overflow values correctly
- delete overflow value, verify no leak (check page_count or free list)
- upsert overflow value twice: old chain freed, new chain correct
- mix of inline and overflow values on same leaf page
- enough overflow values to force leaf split: all readable after split
- free_tree on a btree with overflow cells: no leak
```

---

## What Does NOT Change

- Internal pages: keys in internal pages are always short (promoted leaf keys), never overflow
- WAL: unchanged — overflow pages go through the same WAL write path as any other page
- Raft: unchanged — operates at the page level, doesn't care about page type
- Row codec: unchanged — the codec produces the value bytes; those bytes get stored via overflow if large
- Pager free list: unchanged — `allocate_page` / `free_page` work for overflow pages identically to any other page
- The `OVERFLOW_FLAG` constant was always zero in existing databases, so old databases with inline-only values are forward-compatible with the new reader (new code sees flag=0, treats as inline)

---

## Risk Notes

- **Transaction safety:** Overflow pages are written via `@pager.write_page` which stages them in the WAL's dirty map. If the transaction is rolled back (savepoint pop), the overflow pages will remain dirty but not committed. The WAL rollback discards dirty pages, so the overflow allocation is automatically undone. No special handling needed.
- **Crash recovery:** Overflow pages are written before the leaf page that points to them. A crash after overflow write but before leaf commit means the overflow pages exist in the WAL but no leaf points to them — they're orphaned but not reachable, and will be overwritten when the pager allocates those page numbers again on next startup. This is acceptable (same as SQLite's behavior). A stricter design would track them explicitly, but it's not necessary here.
- **Don't allocate overflow pages speculatively.** Write overflow pages only inside a transaction that's going to succeed — i.e., after the duplicate key check in `insert_into_leaf`, not before.
