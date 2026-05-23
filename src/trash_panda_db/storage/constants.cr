lib LibC
  fun fdatasync(fd : Int32) : Int32
end

module TrashPandaDB::Storage
  PAGE_SIZE    = 32768_u32
  DB_MAGIC     = "TPANDADB"
  WAL_MAGIC    = "TPANDAWL"
  DB_VERSION   = 3_u32

  # DB file header layout (64 bytes total):
  #   0..7   magic (8 bytes)
  #   8..11  version (UInt32 LE)
  #   12..15 page_count (UInt32 LE)
  #   16..19 free_list_head (UInt32 LE, Phase 2)
  #   20..63 reserved (zero-filled)
  DB_HEADER_SIZE  = 64_u32
  DB_MAGIC_OFFSET = 0
  DB_VER_OFFSET   = 8
  DB_PGCOUNT_OFFSET = 12

  # WAL file header layout (32 bytes total):
  #   0..7   magic (8 bytes)
  #   8..11  version (UInt32 LE)
  #   12..31 reserved (zero-filled)
  WAL_HEADER_SIZE = 32_u32

  # WAL frame layout (8 + PAGE_SIZE bytes):
  #   0..3   page_no (UInt32 LE, 1-based)
  #   4..7   flags   (UInt32 LE; bit 0 = commit)
  #   8..    page data (PAGE_SIZE bytes)
  WAL_FRAME_COMMIT = 1_u32
  WAL_FRAME_SIZE   = 8_u32 + PAGE_SIZE

  # ── B+ tree page types ──────────────────────────────────────────────────────
  BTREE_PAGE_FREE      = 0x00_u8
  BTREE_PAGE_INTERNAL  = 0x01_u8
  BTREE_PAGE_LEAF      = 0x02_u8
  BTREE_PAGE_OVERFLOW  = 0x03_u8
  BTREE_PAGE_CATALOG   = 0x04_u8

  # ── Format versions ──────────────────────────────────────────────────────────
  DB_VERSION_JSON     = 1_u32   # old JSON blob format
  DB_VERSION_BTREE    = 2_u32   # B+ tree format, inline values only
  DB_VERSION_OVERFLOW = 3_u32   # B+ tree format with overflow page support

  # ── B+ tree page header sizes ────────────────────────────────────────────────
  LEAF_HEADER_SIZE     = 16_u32
  INTERNAL_HEADER_SIZE = 16_u32
  CELL_PTR_SIZE        = 2_u32

  # ── Overflow pages ────────────────────────────────────────────────────────────
  # Bit 31 of the val_size field in a leaf cell signals an overflow cell.
  # When set, bits 30..0 hold the actual value byte count, and the 4 bytes
  # that would normally hold value data instead hold the first overflow page no.
  #
  # Overflow page layout:
  #   [0]      type      : UInt8  = BTREE_PAGE_OVERFLOW
  #   [1-4]    next_page : UInt32 LE  (0 = last page in chain)
  #   [5-7]    reserved  : 3 bytes (zero)
  #   [8 ..]   data      : PAGE_SIZE - 8 bytes of value content
  OVERFLOW_FLAG      = 0x80000000_u32
  OVERFLOW_HDR_SIZE  = 8_u32
  OVERFLOW_DATA_SIZE = PAGE_SIZE - OVERFLOW_HDR_SIZE
end
