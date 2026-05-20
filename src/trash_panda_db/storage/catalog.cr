require "./constants"
require "./pager"
require "./btree"
require "../sql/database"

module TrashPandaDB::Storage
  CATALOG_PAGE = 1_u32

  class IndexMeta
    getter name : String
    getter table : String
    getter col : String
    getter unique : Bool
    property root_page : UInt32
    def initialize(@name : String, @table : String, @col : String, @root_page : UInt32, @unique : Bool = false); end
  end

  # Persists and loads table schemas, B+ tree root page numbers, and index metadata.
  #
  # Wire format (page 1):
  #   [0]    type : UInt8 = BTREE_PAGE_CATALOG
  #   [1-2]  table_count : UInt16 LE
  #   [3-6]  next_catalog_page : UInt32 LE (0 = none; multi-page catalogue not yet used)
  #   [7-8]  index_count : UInt16 LE
  #   [9-15] reserved
  #   [16..] packed table entries, then packed index entries
  module Catalog
    LE = IO::ByteFormat::LittleEndian

    # Helper: decode a value of type T from an IO
    def self.decode_io(type : T.class, io : IO) : T forall T
      buf = Bytes.new(sizeof(T))
      io.read_fully(buf)
      LE.decode(T, buf)
    end

    # Persist all table schemas + btree root pages + indexes into page 1.
    def self.save(pager : Pager, tables : Hash(String, SQL::Table), btrees : Hash(String, BTree), indexes : Hash(String, IndexMeta) = {} of String => IndexMeta) : Nil
      io = IO::Memory.new(PAGE_SIZE.to_i)
      io.write_byte(BTREE_PAGE_CATALOG)
      LE.encode(tables.size.to_u16, io)   # [1-2] table count
      LE.encode(0_u32, io)                 # [3-6] next_catalog_page
      LE.encode(indexes.size.to_u16, io)  # [7-8] index count
      io.write(Bytes.new(7))              # [9-15] reserved

      tables.each do |name, table|
        root_page = btrees[name]?.try(&.root_page) || 0_u32
        encode_entry(io, name, table.schema, table.next_rowid, root_page)
      end

      indexes.each do |_, meta|
        encode_index_entry(io, meta)
      end

      page = Bytes.new(PAGE_SIZE.to_i)
      data = io.to_slice
      data.copy_to(page)
      pager.write_page(CATALOG_PAGE, page)
    end

    # Load table schemas and index metadata from page 1.
    def self.load(pager : Pager) : NamedTuple(
      tables: Hash(String, NamedTuple(schema: SQL::TableSchema, next_rowid: Int64, root_page: UInt32)),
      indexes: Hash(String, IndexMeta)
    )
      tables = Hash(String, NamedTuple(schema: SQL::TableSchema, next_rowid: Int64, root_page: UInt32)).new
      indexes = Hash(String, IndexMeta).new
      empty = {tables: tables, indexes: indexes}
      return empty if pager.page_count < CATALOG_PAGE

      page = pager.read_page(CATALOG_PAGE)
      return empty unless page[0] == BTREE_PAGE_CATALOG

      table_count = LE.decode(UInt16, page[1, 2]).to_i
      index_count = LE.decode(UInt16, page[7, 2]).to_i
      io = IO::Memory.new(page[16..])

      table_count.times do
        name, schema, next_rowid, root_page = decode_entry(io)
        tables[name] = {schema: schema, next_rowid: next_rowid, root_page: root_page}
      end

      index_count.times do
        meta = decode_index_entry(io)
        indexes[meta.name] = meta
      end

      {tables: tables, indexes: indexes}
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

    private def self.encode_index_entry(io : IO, meta : IndexMeta) : Nil
      [meta.name, meta.table, meta.col].each do |s|
        b = s.to_slice
        io.write_byte(b.size.to_u8)
        io.write(b)
      end
      LE.encode(meta.root_page, io)
      io.write_byte(meta.unique ? 1_u8 : 0_u8)
    end

    private def self.decode_index_entry(io : IO::Memory) : IndexMeta
      strs = Array(String).new(3)
      3.times do
        len = io.read_byte.not_nil!.to_i
        buf = Bytes.new(len); io.read_fully(buf)
        strs << String.new(buf)
      end
      root_page = decode_io(UInt32, io)
      unique = io.read_byte.not_nil! != 0_u8
      IndexMeta.new(strs[0], strs[1], strs[2], root_page, unique)
    end
  end
end