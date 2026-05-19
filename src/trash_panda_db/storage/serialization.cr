require "./constants"
require "json"

module TrashPandaDB::Storage
  # JSON-based serialization for simplicity and debugging
  class Serialization
    METADATA_MAGIC  = "TPDBMETA"
    METADATA_VERSION = 1_u32

    struct TableData
      include JSON::Serializable

      property name : String
      property col_names : Array(String)
      property col_types : Array(String)
      property col_not_nulls : Array(Bool)
      property pk_idx : Int32
      property auto_pk : Bool
      property rows : Array(Array(JSON::Any))

      def initialize(@name, @col_names, @col_types, @col_not_nulls, @pk_idx, @auto_pk, @rows)
      end
    end

    struct DatabaseData
      include JSON::Serializable

      property version : UInt32
      property tables : Array(TableData)

      def initialize(@version, @tables)
      end
    end

    def self.serialize(db : SQL::Database, pager : Pager) : Nil
      return if pager.nil?
      return if db.tables.empty?

      puts "[DEBUG] Serializing #{db.tables.size} tables..." if ENV["DEBUG"]?

      # Convert database to JSON structure
      tables_data = Array(TableData).new

      db.tables.each do |name, table|
        puts "[DEBUG] Serializing table '#{name}' with #{table.rows.size} rows" if ENV["DEBUG"]?

        col_names = table.schema.cols.map(&.name)
        col_types = table.schema.cols.map(&.type_str)
        col_not_nulls = table.schema.cols.map(&.not_null)
        pk_idx = table.schema.pk_idx || -1
        auto_pk = table.schema.auto_pk

        # Convert rows to JSON-serializable format
        rows_data = table.rows.map do |row|
          row.map do |value|
            case value
            when Nil
              JSON::Any.new(nil)
            when Bool
              JSON::Any.new(value)
            when Int64
              JSON::Any.new(value.to_i64)
            when Float64
              JSON::Any.new(value.to_f64)
            when String
              JSON::Any.new(value)
            when Bytes
              JSON::Any.new(value.to_a.map { |b| JSON::Any.new(b.to_i) })
            else
              JSON::Any.new(nil)
            end
          end
        end

        table_data = TableData.new(name, col_names, col_types, col_not_nulls, pk_idx, auto_pk, rows_data)
        tables_data << table_data
      end

      db_data = DatabaseData.new(METADATA_VERSION, tables_data)
      json_string = db_data.to_json

      puts "[DEBUG] JSON size: #{json_string.bytesize} bytes" if ENV["DEBUG"]?

      # Write JSON string to pages
      data_bytes = json_string.to_slice
      current_page = 1_u32
      offset = 0

      while offset < data_bytes.size
        page_buf = Bytes.new(PAGE_SIZE.to_i)
        chunk_size = Math.min(PAGE_SIZE.to_i, data_bytes.size - offset)

        # Copy data to page buffer
        data_bytes[offset, chunk_size].copy_to(page_buf[0, chunk_size])

        pager.write_page(current_page, page_buf)
        current_page += 1
        offset += chunk_size
      end

      puts "[DEBUG] Serialization complete, used #{current_page - 1} pages" if ENV["DEBUG"]?
    end

    def self.deserialize(db : SQL::Database, pager : Pager) : Nil
      return if pager.nil?

      # Check if there are any pages to deserialize
      if pager.page_count < 1
        puts "[DEBUG] No pages to deserialize (page_count: #{pager.page_count})" if ENV["DEBUG"]?
        return
      end

      puts "[DEBUG] Deserializing database with #{pager.page_count} pages..." if ENV["DEBUG"]?

      # Read all data from pages
      data = IO::Memory.new

      (1..pager.page_count).each do |page_no|
        page_buf = pager.read_page(page_no.to_u32)
        data.write(page_buf)
      end

      # Trim trailing null bytes from page alignment padding, then parse JSON
      raw = data.to_slice
      trim_len = raw.size
      while trim_len > 0 && raw[trim_len - 1] == 0_u8
        trim_len -= 1
      end
      json_string = String.new(raw[0, trim_len]).strip

      if json_string.empty? || json_string[0] != '{'
        puts "[DEBUG] Invalid JSON data, first chars: #{json_string[0, 20]}..." if ENV["DEBUG"]?
        return
      end

      puts "[DEBUG] JSON data size: #{json_string.bytesize} bytes" if ENV["DEBUG"]?

      begin
        db_data = DatabaseData.from_json(json_string)
        puts "[DEBUG] Found #{db_data.tables.size} tables in JSON" if ENV["DEBUG"]?

        # Restore tables
        db_data.tables.each do |table_data|
          puts "[DEBUG] Restoring table '#{table_data.name}'" if ENV["DEBUG"]?

          # Create column schemas
          cols = Array(SQL::ColSchema).new
          table_data.col_names.zip(table_data.col_types, table_data.col_not_nulls) do |name, type, not_null|
            cols << SQL::ColSchema.new(name, type, not_null)
          end

          # Create table schema
          pk_names = if table_data.pk_idx >= 0
                       [cols[table_data.pk_idx].name]
                     else
                       [] of String
                     end

          schema = SQL::TableSchema.new(table_data.name, cols, pk_names)

          # Convert JSON rows to database rows
          rows = Array(Array(SQL::Value)).new
          max_rowid = 0_i64

          table_data.rows.each do |json_row|
            row = Array(SQL::Value).new
            json_row.each_with_index do |json_value, col_idx|
              value = case json_value.raw
                      when Nil
                        nil.as(SQL::Value)
                      when Bool
                        json_value.as_bool.as(SQL::Value)
                      when Int64
                        val = json_value.as_i64
                        if col_idx == table_data.pk_idx
                          max_rowid = val if val > max_rowid
                        end
                        val.as(SQL::Value)
                      when Float64
                        json_value.as_f.as(SQL::Value)
                      when String
                        json_value.as_s.as(SQL::Value)
                      when Array
                        # Convert array to Bytes
                        bytes_arr = json_value.as_a.map(&.as_i.to_u8)
                        Bytes.new(bytes_arr.to_unsafe, bytes_arr.size).as(SQL::Value)
                      else
                        nil.as(SQL::Value)
                      end

              row << value
            end

            rows << row
          end

          # Create table
          table = SQL::Table.new(schema, rows, max_rowid + 1)

          # Add to database
          db.set_table(table_data.name, table)
          puts "[DEBUG] Successfully restored table '#{table_data.name}' with #{rows.size} rows" if ENV["DEBUG"]?
        end
      rescue ex
        puts "[DEBUG] Failed to parse JSON: #{ex.message}" if ENV["DEBUG"]?
        puts "[DEBUG] JSON content: #{json_string[0, 100]}..." if ENV["DEBUG"]?
      end
    end
  end
end