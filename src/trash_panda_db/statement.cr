class TrashPandaDB::Statement < DB::Statement
  def initialize(connection : DB::Connection, command : String)
    super(connection, command)
  end

  protected def perform_query(args : Enumerable) : DB::ResultSet
    conn = @connection.as(Connection)
    bound = coerce_args(args)
    result = conn.sql_db.execute(@command, bound, conn.in_transaction?)
    case result
    when SQL::QueryResult
      ResultSet.new(self, result.rows, result.col_names)
    else
      ResultSet.new(self)
    end
  end

  protected def perform_exec(args : Enumerable) : DB::ExecResult
    conn = @connection.as(Connection)
    bound = coerce_args(args)
    result = conn.sql_db.execute(@command, bound, conn.in_transaction?)
    conn.sync_to_storage
    case result
    when SQL::ExecResult
      DB::ExecResult.new(result.rows_affected, result.last_insert_id)
    else
      DB::ExecResult.new(0_i64, 0_i64)
    end
  end

  protected def do_close
  end

  # Convert DB::Any arguments to SQL::Value, widening small int/float types.
  private def coerce_args(args : Enumerable) : Array(SQL::Value)
    result = Array(SQL::Value).new
    args.each { |v| result << coerce_one(v) }
    result
  end

  private def coerce_one(v) : SQL::Value
    case v
    when Nil     then nil
    when Bool    then v ? 1_i64 : 0_i64
    when Int64   then v
    when Int32   then v.to_i64
    when Int16   then v.to_i64
    when Int8    then v.to_i64
    when UInt64  then v.to_i64
    when UInt32  then v.to_i64
    when UInt16  then v.to_i64
    when UInt8   then v.to_i64
    when Float64 then v
    when Float32 then v.to_f64
    when String  then v
    when Bytes   then v
    when Time    then v.to_s(TrashPandaDB::DATE_FORMAT_SUBSECOND_Z)
    else              nil
    end
  end
end
