class TrashPandaDB::ResultSet < DB::ResultSet
  @rows : Array(SQL::Row)
  @col_names : Array(String)
  @row_idx : Int32
  @col_idx : Int32

  def initialize(statement : DB::Statement, @rows : Array(SQL::Row), @col_names : Array(String))
    super(statement)
    @row_idx = -1
    @col_idx = 0
  end

  def initialize(statement : DB::Statement)
    super(statement)
    @rows = [] of SQL::Row
    @col_names = [] of String
    @row_idx = -1
    @col_idx = 0
  end

  def move_next : Bool
    @row_idx += 1
    @col_idx = 0
    @row_idx < @rows.size
  end

  def column_count : Int32
    @col_names.size
  end

  def column_name(index : Int32) : String
    @col_names[index]? || ""
  end

  def next_column_index : Int32
    @col_idx
  end

  # Reads the next column value as DB::Any.
  # Uses safe array access: pre-migration rows may have fewer elements than the
  # current schema if columns were added via ALTER TABLE ADD COLUMN after the
  # row was stored. Missing columns are returned as nil (NULL).
  def read : DB::Any
    row = @rows[@row_idx]
    val = row[@col_idx]?
    @col_idx += 1
    case val
    when Nil     then nil
    when Bool    then val
    when Int64   then val
    when Float64 then val
    when String  then val
    when Bytes   then val
    else nil
    end
  end

  # ── Typed read overloads ──────────────────────────────────────────────────

  # Int64 / Int64? — the native integer type in TrashPandaDB.
  # Defining these explicitly prevents crystal-db's generic read(T.class) from
  # being used, which would raise DB::ColumnTypeMismatchError for nil values
  # instead of returning nil (for the nullable variant).
  def read(t : Int64.class) : Int64
    col_idx = @col_idx
    val = read
    case val
    when Int64   then val
    when Float64 then val.to_i64
    when Nil
      raise DB::ColumnTypeMismatchError.new(
        context: "#{self.class}#read",
        column_index: col_idx,
        column_name: column_name(col_idx),
        column_type: "Nil",
        expected_type: "Int64"
      )
    else
      raise DB::ColumnTypeMismatchError.new(
        context: "#{self.class}#read",
        column_index: col_idx,
        column_name: column_name(col_idx),
        column_type: val.class.to_s,
        expected_type: "Int64"
      )
    end
  end

  def read(t : Int64?.class) : Int64?
    val = read
    case val
    when Int64   then val
    when Nil     then nil
    when Float64 then val.to_i64
    else nil
    end
  end

  # Float64 / Float64?
  def read(t : Float64.class) : Float64
    col_idx = @col_idx
    val = read
    case val
    when Float64 then val
    when Int64   then val.to_f64
    when Nil
      raise DB::ColumnTypeMismatchError.new(
        context: "#{self.class}#read",
        column_index: col_idx,
        column_name: column_name(col_idx),
        column_type: "Nil",
        expected_type: "Float64"
      )
    else
      raise DB::ColumnTypeMismatchError.new(
        context: "#{self.class}#read",
        column_index: col_idx,
        column_name: column_name(col_idx),
        column_type: val.class.to_s,
        expected_type: "Float64"
      )
    end
  end

  def read(t : Float64?.class) : Float64?
    val = read
    case val
    when Float64 then val
    when Int64   then val.to_f64
    when Nil     then nil
    else nil
    end
  end

  # String / String?
  def read(t : String.class) : String
    col_idx = @col_idx
    val = read
    case val
    when String then val
    else
      raise DB::ColumnTypeMismatchError.new(
        context: "#{self.class}#read",
        column_index: col_idx,
        column_name: column_name(col_idx),
        column_type: val.class.to_s,
        expected_type: "String"
      )
    end
  end

  def read(t : String?.class) : String?
    col_idx = @col_idx
    val = read
    case val
    when String then val
    when Nil    then nil
    else
      raise DB::ColumnTypeMismatchError.new(
        context: "#{self.class}#read",
        column_index: col_idx,
        column_name: column_name(col_idx),
        column_type: val.class.to_s,
        expected_type: "String | Nil"
      )
    end
  end

  def read(t : UInt8.class) : UInt8
    read(Int64).to_u8
  end

  def read(t : UInt8?.class) : UInt8?
    read(Int64?).try &.to_u8
  end

  def read(t : UInt16.class) : UInt16
    read(Int64).to_u16
  end

  def read(t : UInt16?.class) : UInt16?
    read(Int64?).try &.to_u16
  end

  def read(t : UInt32.class) : UInt32
    read(Int64).to_u32
  end

  def read(t : UInt32?.class) : UInt32?
    read(Int64?).try &.to_u32
  end

  def read(t : Int8.class) : Int8
    read(Int64).to_i8
  end

  def read(t : Int8?.class) : Int8?
    read(Int64?).try &.to_i8
  end

  def read(t : Int16.class) : Int16
    read(Int64).to_i16
  end

  def read(t : Int16?.class) : Int16?
    read(Int64?).try &.to_i16
  end

  def read(t : Int32.class) : Int32
    read(Int64).to_i32
  end

  def read(t : Int32?.class) : Int32?
    read(Int64?).try &.to_i32
  end

  def read(t : Float32.class) : Float32
    read(Float64).to_f32
  end

  def read(t : Float32?.class) : Float32?
    read(Float64?).try &.to_f32
  end

  def read(t : Time.class) : Time
    text = read(String)
    parse_time(text)
  end

  def read(t : Time?.class) : Time?
    read(String?).try { |v| parse_time(v) }
  end

  private def parse_time(text : String) : Time
    if text.includes?("+") || text.includes?(" -")
      Time.parse(text, TrashPandaDB::DATE_FORMAT_SUBSECOND_Z, TrashPandaDB::TIME_ZONE)
    elsif text.includes?(".")
      Time.parse(text, TrashPandaDB::DATE_FORMAT_SUBSECOND, location: TrashPandaDB::TIME_ZONE)
    else
      Time.parse(text, TrashPandaDB::DATE_FORMAT_SECOND, location: TrashPandaDB::TIME_ZONE)
    end
  end

  def read(t : Bool.class) : Bool
    read(Int64) != 0
  end

  def read(t : Bool?.class) : Bool?
    read(Int64?).try &.!=(0)
  end

  protected def do_close
  end
end
