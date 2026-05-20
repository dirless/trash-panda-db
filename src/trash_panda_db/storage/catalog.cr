require "./constants"
require "./pager"
require "./btree"
require "../sql/database"

module TrashPandaDB::Storage
  CATALOG_PAGE = 1_u32

  class IndexMeta
    getter name : String
    getter table : String
    getter cols : Array(String)
    getter unique : Bool
    property root_page : UInt32
    def initialize(@name : String, @table : String, @cols : Array(String), @root_page : UInt32, @unique : Bool = false); end
    def col : String; @cols[0]; end
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

    # Persist all table schemas + btree root pages + indexes, spanning multiple pages if needed.
    def self.save(pager : Pager, tables : Hash(String, SQL::Table), btrees : Hash(String, BTree), indexes : Hash(String, IndexMeta) = {} of String => IndexMeta) : Nil
      # Collect existing overflow page chain so we can reuse or free pages.
      old_overflow = [] of UInt32
      if pager.page_count >= CATALOG_PAGE
        p1 = pager.read_page(CATALOG_PAGE)
        if p1[0] == BTREE_PAGE_CATALOG
          np = LE.decode(UInt32, p1[3, 4])
          while np != 0
            old_overflow << np
            cont = pager.read_page(np)
            np = LE.decode(UInt32, cont[0, 4])
          end
        end
      end

      # Serialize all entries into one buffer (no size limit).
      content = IO::Memory.new
      tables.each do |name, table|
        root_page = btrees[name]?.try(&.root_page) || 0_u32
        encode_entry(content, name, table.schema, table.next_rowid, root_page)
      end
      indexes.each { |_, meta| encode_index_entry(content, meta) }
      content_bytes = content.to_slice

      # Page 1: 16-byte header + up to (PAGE_SIZE-16) bytes of content.
      # Continuation pages: 4-byte next_page + up to (PAGE_SIZE-4) bytes of content.
      page1_cap = PAGE_SIZE.to_i - 16
      cont_cap  = PAGE_SIZE.to_i - 4

      # Split into chunks.
      chunks = [] of Bytes
      if content_bytes.size <= page1_cap
        chunks << content_bytes
      else
        chunks << content_bytes[0, page1_cap]
        rest = content_bytes[page1_cap..]
        while rest.size > 0
          sz = Math.min(rest.size, cont_cap)
          chunks << rest[0, sz]
          rest = rest[sz..]
        end
      end

      # Assign page numbers for continuation chunks (reuse old pages first).
      cont_page_nos = Array(UInt32).new
      (chunks.size - 1).times do |i|
        cont_page_nos << (i < old_overflow.size ? old_overflow[i] : pager.allocate_page)
      end

      # Free old overflow pages no longer needed.
      old_overflow.each_with_index do |pg, i|
        pager.free_page(pg) if i >= cont_page_nos.size
      end

      # Write page 1.
      io1 = IO::Memory.new(PAGE_SIZE.to_i)
      io1.write_byte(BTREE_PAGE_CATALOG)
      LE.encode(tables.size.to_u16, io1)
      LE.encode(cont_page_nos.first? || 0_u32, io1)
      LE.encode(indexes.size.to_u16, io1)
      io1.write(Bytes.new(7))
      io1.write(chunks[0])
      page1 = Bytes.new(PAGE_SIZE.to_i)
      io1.to_slice.copy_to(page1)
      pager.write_page(CATALOG_PAGE, page1)

      # Write continuation pages.
      cont_page_nos.each_with_index do |pg_no, i|
        ioc = IO::Memory.new(PAGE_SIZE.to_i)
        next_no = i + 1 < cont_page_nos.size ? cont_page_nos[i + 1] : 0_u32
        LE.encode(next_no, ioc)
        ioc.write(chunks[i + 1])
        cont_page = Bytes.new(PAGE_SIZE.to_i)
        ioc.to_slice.copy_to(cont_page)
        pager.write_page(pg_no, cont_page)
      end
    end

    # Load table schemas and index metadata, following the multi-page chain.
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
      next_np     = LE.decode(UInt32, page[3, 4])
      index_count = LE.decode(UInt16, page[7, 2]).to_i

      # Assemble full content from page 1 + continuation chain.
      content = IO::Memory.new
      content.write(page[16, page.size - 16])
      while next_np != 0
        cont = pager.read_page(next_np)
        next_np = LE.decode(UInt32, cont[0, 4])
        content.write(cont[4, cont.size - 4])
      end
      content.rewind

      table_count.times do
        name, schema, next_rowid, root_page = decode_entry(content)
        tables[name] = {schema: schema, next_rowid: next_rowid, root_page: root_page}
      end

      index_count.times do
        meta = decode_index_entry(content)
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
        if dsql = col.default_sql
          b = dsql.to_slice
          io.write_byte(1_u8)
          LE.encode(b.size.to_u16, io)
          io.write(b)
        else
          io.write_byte(0_u8)
        end
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
        has_default = io.read_byte.not_nil! != 0_u8
        default_sql = if has_default
          dl = decode_io(UInt16, io).to_i
          db2 = Bytes.new(dl); io.read_fully(db2); String.new(db2)
        else
          nil
        end
        cols << SQL::ColSchema.new(col_name, col_type, not_null, default_sql)
      end

      pk_col_names = pk_idx_raw >= 0 ? [cols[pk_idx_raw].name] : [] of String
      schema = SQL::TableSchema.new(name, cols, pk_col_names)
      {name, schema, next_rowid, root_page}
    end

    private def self.encode_index_entry(io : IO, meta : IndexMeta) : Nil
      [meta.name, meta.table].each do |s|
        b = s.to_slice; io.write_byte(b.size.to_u8); io.write(b)
      end
      io.write_byte(meta.cols.size.to_u8)
      meta.cols.each do |s|
        b = s.to_slice; io.write_byte(b.size.to_u8); io.write(b)
      end
      LE.encode(meta.root_page, io)
      io.write_byte(meta.unique ? 1_u8 : 0_u8)
    end

    private def self.decode_index_entry(io : IO::Memory) : IndexMeta
      read_str = ->(i : IO::Memory) {
        len = i.read_byte.not_nil!.to_i
        buf = Bytes.new(len); i.read_fully(buf); String.new(buf)
      }
      name  = read_str.call(io)
      table = read_str.call(io)
      col_count = io.read_byte.not_nil!.to_i
      cols = Array(String).new(col_count) { read_str.call(io) }
      root_page = decode_io(UInt32, io)
      unique = io.read_byte.not_nil! != 0_u8
      IndexMeta.new(name, table, cols, root_page, unique)
    end
  end
end