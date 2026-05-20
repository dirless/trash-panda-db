require "./constants"
require "./pager"
require "./btree"
require "../sql/database"

module TrashPandaDB::Storage
  CATALOG_PAGE = 1_u32

  # Persists and loads table schemas and B+ tree root page numbers.
  #
  # Wire format (page 1):
  #   [0]    type : UInt8 = BTREE_PAGE_CATALOG
  #   [1-2]  entry_count : UInt16 LE
  #   [3-6]  next_catalog_page : UInt32 LE (0 = none; multi-page catalogue not yet used)
  #   [7-15] reserved
  #   [16..] packed entries — see encode_entry / decode_entry below
  module Catalog
    LE = IO::ByteFormat::LittleEndian

    # Helper: decode a value of type T from an IO
    def self.decode_io(type : T.class, io : IO) : T forall T
      buf = Bytes.new(sizeof(T))
      io.read_fully(buf)
      LE.decode(T, buf)
    end

    # Persist all table schemas + btree root pages from db into page 1.
    def self.save(pager : Pager, tables : Hash(String, SQL::Table), btrees : Hash(String, BTree)) : Nil
      io = IO::Memory.new(PAGE_SIZE.to_i)
      io.write_byte(BTREE_PAGE_CATALOG)
      LE.encode(tables.size.to_u16, io)
      LE.encode(0_u32, io)  # next_catalog_page
      io.write(Bytes.new(9)) # reserved

      tables.each do |name, table|
        root_page = btrees[name]?.try(&.root_page) || 0_u32
        encode_entry(io, name, table.schema, table.next_rowid, root_page)
      end

      page = Bytes.new(PAGE_SIZE.to_i)
      data = io.to_slice
      data.copy_to(page)
      pager.write_page(CATALOG_PAGE, page)
    end

    # Load table schemas from page 1 into db.
    # Returns a Hash(String, NamedTuple(schema: SQL::TableSchema, next_rowid: Int64, root_page: UInt32))
    def self.load(pager : Pager) : Hash(String, NamedTuple(schema: SQL::TableSchema, next_rowid: Int64, root_page: UInt32))
      result = Hash(String, NamedTuple(schema: SQL::TableSchema, next_rowid: Int64, root_page: UInt32)).new
      return result if pager.page_count < CATALOG_PAGE

      page = pager.read_page(CATALOG_PAGE)
      return result unless page[0] == BTREE_PAGE_CATALOG

      entry_count = LE.decode(UInt16, page[1, 2]).to_i
      io = IO::Memory.new(page[16..])

      entry_count.times do
        name, schema, next_rowid, root_page = decode_entry(io)
        result[name] = {schema: schema, next_rowid: next_rowid, root_page: root_page}
      end
      result
    end

    private def self.encode_entry(io : IO, name : String, schema : SQL::TableSchema, next_rowid : Int64, root_page : UInt32) : Nil
      name_bytes = name.to_slice
      io.write_byte(name_bytes.size.to_u8)
      io.write(name_bytes)
      LE.encode(root_page, io)
      LE.encode(schema.cols.size.to_u16, io)
      pk_idx_val = schema.pk_idx || -1
      LE.encode(pk_idx_val.to_i16, io)
      io.write_byte(schema.auto_pk ? 1_u8 : 0_u8)
      LE.encode(next_rowid, io)
      schema.cols.each do |col|
        col_name = col.name.to_slice
        col_type = col.type_str.to_slice
        io.write_byte(col_name.size.to_u8)
        io.write(col_name)
        io.write_byte(col_type.size.to_u8)
        io.write(col_type)
        io.write_byte(col.not_null ? 1_u8 : 0_u8)
      end
    end

    private def self.decode_entry(io : IO::Memory) : Tuple(String, SQL::TableSchema, Int64, UInt32)
      name_len = io.read_byte.not_nil!.to_i
      name_buf = Bytes.new(name_len); io.read_fully(name_buf)
      name = String.new(name_buf)

      root_page = decode_io(UInt32, io)
      col_count = decode_io(UInt16, io).to_i
      pk_idx_raw = decode_io(Int16, io).to_i
      auto_pk = io.read_byte.not_nil! != 0_u8
      next_rowid = decode_io(Int64, io)

      cols = Array(SQL::ColSchema).new(col_count)
      col_count.times do
        cn_len = io.read_byte.not_nil!.to_i
        cn_buf = Bytes.new(cn_len); io.read_fully(cn_buf)
        col_name = String.new(cn_buf)

        ct_len = io.read_byte.not_nil!.to_i
        ct_buf = Bytes.new(ct_len); io.read_fully(ct_buf)
        col_type = String.new(ct_buf)

        not_null = io.read_byte.not_nil! != 0_u8
        cols << SQL::ColSchema.new(col_name, col_type, not_null)
      end

      pk_col_names = pk_idx_raw >= 0 ? [cols[pk_idx_raw].name] : [] of String
      schema = SQL::TableSchema.new(name, cols, pk_col_names)
      {name, schema, next_rowid, root_page}
    end
  end
end