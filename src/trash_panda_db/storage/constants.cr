module TrashPandaDB::Storage
  PAGE_SIZE    = 4096_u32
  DB_MAGIC     = "TPANDADB"
  WAL_MAGIC    = "TPANDAWL"
  DB_VERSION   = 1_u32

  # DB file header layout (64 bytes total):
  #   0..7   magic (8 bytes)
  #   8..11  version (UInt32 LE)
  #   12..15 page_count (UInt32 LE) — total allocated pages
  #   16..63 reserved (zero-filled)
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
end
