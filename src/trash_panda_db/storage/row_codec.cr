require "../sql/value"

module TrashPandaDB::Storage
  # Encodes/decodes Array(SQL::Value) to/from compact binary.
  #
  # Wire format:
  #   col_count   : UInt16 LE
  #   null_bitmap : ceil(col_count / 8) bytes  (bit i=1 → column i is NULL)
  #   For each non-null column in order:
  #     tag  : UInt8   1=Int64  2=Float64  3=Text  4=Blob  5=Bool
  #     data :
  #       Int64   → 8 bytes LE
  #       Float64 → 8 bytes LE (IEEE 754 little-endian)
  #       Text    → UInt32 LE length + UTF-8 bytes
  #       Blob    → UInt32 LE length + raw bytes
  #       Bool    → UInt8 (0 = false, 1 = true)
  module RowCodec
    LE = IO::ByteFormat::LittleEndian

    TAG_INT64   = 1_u8
    TAG_FLOAT64 = 2_u8
    TAG_TEXT    = 3_u8
    TAG_BLOB    = 4_u8
    TAG_BOOL    = 5_u8

    def self.encode(row : Array(SQL::Value)) : Bytes
      io = IO::Memory.new
      col_count = row.size.to_u16
      LE.encode(col_count, io)

      # null bitmap
      bitmap_bytes = (row.size + 7) // 8
      bitmap = Bytes.new(bitmap_bytes, 0_u8)
      row.each_with_index do |v, i|
        bitmap[i // 8] |= (1_u8 << (i % 8)) if v.nil?
      end
      io.write(bitmap)

      # payload for non-null columns
      row.each do |v|
        case v
        when Nil
          # already encoded in bitmap
        when Bool
          io.write_byte(TAG_BOOL)
          io.write_byte(v ? 1_u8 : 0_u8)
        when Int64
          io.write_byte(TAG_INT64)
          LE.encode(v, io)
        when Float64
          io.write_byte(TAG_FLOAT64)
          LE.encode(v, io)
        when String
          io.write_byte(TAG_TEXT)
          bytes = v.to_slice
          LE.encode(bytes.size.to_u32, io)
          io.write(bytes)
        when Bytes
          io.write_byte(TAG_BLOB)
          LE.encode(v.size.to_u32, io)
          io.write(v)
        end
      end

      io.to_slice
    end

    def self.decode(data : Bytes) : Array(SQL::Value)
      io = IO::Memory.new(data)
      col_count_buf = Bytes.new(2)
      io.read_fully(col_count_buf)
      col_count = LE.decode(UInt16, col_count_buf).to_i

      bitmap_bytes = (col_count + 7) // 8
      bitmap = Bytes.new(bitmap_bytes)
      io.read_fully(bitmap)

      row = Array(SQL::Value).new(col_count, nil.as(SQL::Value))

      col_count.times do |i|
        next if (bitmap[i // 8] & (1_u8 << (i % 8))) != 0  # null

        tag = io.read_byte.not_nil!
        row[i] = case tag
        when TAG_INT64
          buf = Bytes.new(8); io.read_fully(buf); LE.decode(Int64, buf).as(SQL::Value)
        when TAG_FLOAT64
          buf = Bytes.new(8); io.read_fully(buf); LE.decode(Float64, buf).as(SQL::Value)
        when TAG_TEXT
          lbuf = Bytes.new(4); io.read_fully(lbuf)
          len = LE.decode(UInt32, lbuf).to_i
          sbuf = Bytes.new(len); io.read_fully(sbuf)
          String.new(sbuf).as(SQL::Value)
        when TAG_BLOB
          lbuf = Bytes.new(4); io.read_fully(lbuf)
          len = LE.decode(UInt32, lbuf).to_i
          bbuf = Bytes.new(len); io.read_fully(bbuf)
          bbuf.as(SQL::Value)
        when TAG_BOOL
          b = io.read_byte.not_nil!; (b != 0_u8).as(SQL::Value)
        else
          nil.as(SQL::Value)
        end
      end

      row
    end

    # Encode a rowid (Int64) as an 8-byte big-endian key.
    # Big-endian preserves integer sort order for binary key comparison.
    def self.encode_key(rowid : Int64) : Bytes
      buf = Bytes.new(8)
      buf[0] = ((rowid >> 56) & 0xFF).to_u8
      buf[1] = ((rowid >> 48) & 0xFF).to_u8
      buf[2] = ((rowid >> 40) & 0xFF).to_u8
      buf[3] = ((rowid >> 32) & 0xFF).to_u8
      buf[4] = ((rowid >> 24) & 0xFF).to_u8
      buf[5] = ((rowid >> 16) & 0xFF).to_u8
      buf[6] = ((rowid >>  8) & 0xFF).to_u8
      buf[7] = ((rowid      ) & 0xFF).to_u8
      buf
    end

    def self.decode_key(buf : Bytes) : Int64
      (buf[0].to_i64 << 56) | (buf[1].to_i64 << 48) |
      (buf[2].to_i64 << 40) | (buf[3].to_i64 << 32) |
      (buf[4].to_i64 << 24) | (buf[5].to_i64 << 16) |
      (buf[6].to_i64 <<  8) |  buf[7].to_i64
    end
  end
end