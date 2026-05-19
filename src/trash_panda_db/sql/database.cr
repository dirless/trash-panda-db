require "../storage/pager"

module TrashPandaDB::SQL
  abstract class ExecuteResult; end

  class QueryResult < ExecuteResult
    getter col_names : Array(String)
    getter rows : Array(Row)
    def initialize(@col_names : Array(String), @rows : Array(Row)); end
  end

  class ExecResult < ExecuteResult
    getter rows_affected : Int64
    getter last_insert_id : Int64
    def initialize(@rows_affected : Int64, @last_insert_id : Int64); end
  end

  # ── Schema & Storage ─────────────────────────────────────────────────────────

  class ColSchema
    getter name : String
    getter type_str : String  # original type string, uppercased
    getter not_null : Bool

    def initialize(@name : String, type_str : String, @not_null : Bool)
      @type_str = type_str.upcase
    end
  end

  class TableSchema
    getter name : String
    getter cols : Array(ColSchema)
    getter pk_idx : Int32?   # column index of the primary key
    getter auto_pk : Bool    # INTEGER PRIMARY KEY => autoincrement rowid

    def initialize(@name : String, @cols : Array(ColSchema), pk_col_names : Array(String))
      pk_name = pk_col_names.first?
      @pk_idx = @cols.index { |c| c.name == pk_name } if pk_name
      @auto_pk = if i = @pk_idx
        @cols[i].type_str.includes?("INT")
      else
        false
      end
    end

    def col_index(name : String) : Int32
      @cols.index { |c| c.name == name } ||
        raise DB::Error.new("no such column: #{name}")
    end
  end

  class Table
    getter schema : TableSchema
    property rows : Array(Row)
    property next_rowid : Int64

    def initialize(@schema : TableSchema)
      @rows = Array(Row).new
      @next_rowid = 1_i64
    end

    def initialize(@schema : TableSchema, @rows : Array(Row), @next_rowid : Int64); end

    def deep_copy : Table
      Table.new(@schema, @rows.map(&.dup), @next_rowid)
    end
  end

  # Snapshot used for transaction rollback.
  private class Snapshot
    getter tables : Hash(String, Table)
    getter last_insert_rowid : Int64

    def initialize(@tables : Hash(String, Table), @last_insert_rowid : Int64); end
  end

  # ── Parameter binder ─────────────────────────────────────────────────────────

  # Each ? in parsed SQL carries its 0-based positional index; the binder
  # maps that index to the argument value for O(1) random-access lookup.
  class ParamBinder
    def initialize(@args : Array(Value)); end

    def get(idx : Int32) : Value
      raise DB::Error.new("parameter index #{idx} out of range (have #{@args.size})") if idx >= @args.size
      @args[idx]
    end
  end

  # ── Database ─────────────────────────────────────────────────────────────────

  class Database
    getter tables : Hash(String, Table)
    @last_insert_rowid : Int64
    @tx_stack : Array(Snapshot)
    # Snapshot of committed state at outermost BEGIN — used for read-committed
    # isolation: connections not inside a transaction read this view.
    @committed_tables : Hash(String, Table)?
    @mutex : Mutex
    @pager : Storage::Pager?

    def initialize(@pager : Storage::Pager? = nil)
      @tables = Hash(String, Table).new
      @committed_tables = nil
      @last_insert_rowid = 0_i64
      @tx_stack = Array(Snapshot).new
      @mutex = Mutex.new
    end

    # in_txn: true  → caller is inside a transaction → sees live (uncommitted) state
    # in_txn: false → caller has no active transaction → sees committed snapshot if one exists
    def execute(sql : String, args : Array(Value), in_txn : Bool = false) : ExecuteResult
      @mutex.synchronize do
        stmt = Parser.new(Lexer.new(sql).tokenize).parse
        binder = ParamBinder.new(args)
        if !in_txn && !@tx_stack.empty? && stmt.is_a?(AST::Select)
          if committed = @committed_tables
            saved = @tables
            @tables = committed
            result = exec_stmt(stmt, binder)
            @tables = saved
            return result
          end
        end
        exec_stmt(stmt, binder)
      end
    end

    # Directly set a table (used by persistence system)
    protected def set_table(name : String, table : Table) : Nil
      @mutex.synchronize { @tables[name] = table }
    end

    # ── Transaction helpers ───────────────────────────────────────────────────

    def begin_transaction : Nil
      @mutex.synchronize do
        @committed_tables = deep_copy_tables if @tx_stack.empty?
        @tx_stack << Snapshot.new(deep_copy_tables, @last_insert_rowid)
      end
    end

    def commit_transaction : Nil
      @mutex.synchronize do
        @tx_stack.pop?
        @committed_tables = nil if @tx_stack.empty?
      end
    end

    def rollback_transaction : Nil
      @mutex.synchronize do
        if snap = @tx_stack.pop?
          @tables = snap.tables
          @last_insert_rowid = snap.last_insert_rowid
        end
        @committed_tables = nil if @tx_stack.empty?
      end
    end

    def create_savepoint(name : String) : Nil
      @mutex.synchronize do
        @tx_stack << Snapshot.new(deep_copy_tables, @last_insert_rowid)
      end
    end

    def release_savepoint(name : String) : Nil
      @mutex.synchronize { @tx_stack.pop? }
    end

    # crystal-db does NOT call release_savepoint after a savepoint rollback, so
    # we must pop the snapshot ourselves to keep @tx_stack consistent.
    def rollback_to_savepoint(name : String) : Nil
      @mutex.synchronize do
        if snap = @tx_stack.pop?
          @tables = snap.tables.transform_values(&.deep_copy)
          @last_insert_rowid = snap.last_insert_rowid
        end
      end
    end

    # ── Statement dispatch ────────────────────────────────────────────────────

    private def exec_stmt(stmt : AST::Stmt, binder : ParamBinder) : ExecuteResult
      case stmt
      when AST::CreateTable     then exec_create_table(stmt, binder)
      when AST::Insert          then exec_insert(stmt, binder)
      when AST::Select          then exec_select(stmt, binder)
      when AST::Update          then exec_update(stmt, binder)
      when AST::Delete          then exec_delete(stmt, binder)
      when AST::DropTable       then exec_drop_table(stmt, binder)
      when AST::Begin           then begin_transaction;   ExecResult.new(0_i64, 0_i64)
      when AST::Commit          then commit_transaction;  ExecResult.new(0_i64, 0_i64)
      when AST::Rollback        then rollback_transaction; ExecResult.new(0_i64, 0_i64)
      when AST::Savepoint       then create_savepoint(stmt.name);   ExecResult.new(0_i64, 0_i64)
      when AST::ReleaseSavepoint  then release_savepoint(stmt.name); ExecResult.new(0_i64, 0_i64)
      when AST::RollbackTo      then rollback_to_savepoint(stmt.name); ExecResult.new(0_i64, 0_i64)
      else
        raise DB::Error.new("unsupported statement #{stmt.class}")
      end
    end

    # ── CREATE TABLE ──────────────────────────────────────────────────────────

    private def exec_create_table(stmt : AST::CreateTable, binder : ParamBinder) : ExecuteResult
      name = stmt.tbl
      if @tables.has_key?(name)
        return ExecResult.new(0_i64, 0_i64) if stmt.if_not_exists
        raise DB::Error.new("table #{name} already exists")
      end

      col_schemas = stmt.col_defs.map { |c| ColSchema.new(c.name, c.type_str, c.not_null) }

      # Determine which columns are PKs
      pk_names = stmt.table_pk.dup
      stmt.col_defs.each { |c| pk_names << c.name if c.pk }
      pk_names.uniq!

      schema = TableSchema.new(name, col_schemas, pk_names)
      @tables[name] = Table.new(schema)
      ExecResult.new(0_i64, 0_i64)
    end

    # ── INSERT ────────────────────────────────────────────────────────────────

    private def exec_insert(stmt : AST::Insert, binder : ParamBinder) : ExecuteResult
      table = @tables[stmt.tbl]? || raise DB::Error.new("no such table: #{stmt.tbl}")
      schema = table.schema
      rows_affected = 0_i64

      stmt.value_rows.each do |val_exprs|
        # Build a full row (all columns, initialized to nil)
        row = Array(Value).new(schema.cols.size, nil.as(Value))

        if stmt.col_names.empty?
          val_exprs.each_with_index do |val_expr, i|
            row[i] = eval_expr(val_expr, row, schema, binder) if i < schema.cols.size
          end
        else
          stmt.col_names.each_with_index do |col_name, i|
            col_idx = schema.col_index(col_name)
            row[col_idx] = eval_expr(val_exprs[i], row, schema, binder)
          end
        end

        # Autoincrement PK
        if pk_idx = schema.pk_idx
          if schema.auto_pk
            if row[pk_idx].nil?
              row[pk_idx] = table.next_rowid
              table.next_rowid += 1
            else
              pk_val = row[pk_idx]
              if pk_val.is_a?(Int64) && pk_val >= table.next_rowid
                table.next_rowid = pk_val + 1
              end
            end
          end
        end

        # Conflict resolution
        pk_idx = schema.pk_idx
        if pk_idx
          pk_val = row[pk_idx]
          existing_idx = pk_val.nil? ? nil : table.rows.index { |r| r[pk_idx] == pk_val }

          case stmt.conflict
          when AST::Insert::Conflict::Replace
            if existing_idx
              table.rows[existing_idx] = row
            else
              table.rows << row
            end
          when AST::Insert::Conflict::Ignore
            table.rows << row unless existing_idx
          else
            if existing_idx
              raise DB::Error.new("UNIQUE constraint failed: #{schema.name}.#{schema.cols[pk_idx].name}")
            end
            table.rows << row
          end
        else
          table.rows << row
        end

        @last_insert_rowid = begin
          if pk_idx = schema.pk_idx
            v = row[pk_idx]
            v.is_a?(Int64) ? v : table.rows.size.to_i64
          else
            table.rows.size.to_i64
          end
        end
        rows_affected += 1
      end

      ExecResult.new(rows_affected, @last_insert_rowid)
    end

    # ── SELECT ────────────────────────────────────────────────────────────────

    private def exec_select(stmt : AST::Select, binder : ParamBinder) : ExecuteResult
      from_tbl = stmt.from_tbl

      # SELECT LAST_INSERT_ROWID() — no FROM
      if from_tbl.nil? && stmt.sel_cols.size == 1
        col = stmt.sel_cols[0]
        if (expr = col.expr).is_a?(AST::FnCall) && expr.fn == "LAST_INSERT_ROWID"
          return QueryResult.new(["LAST_INSERT_ROWID()"], [[@last_insert_rowid.as(Value)]])
        end
      end

      # SELECT 1 (no FROM, literal)
      if from_tbl.nil?
        col_names = stmt.sel_cols.map { |sc| sel_col_name(sc) }
        result_row = stmt.sel_cols.map { |sc| eval_expr(sc.expr, [] of Value, nil, binder) }
        return QueryResult.new(col_names, [result_row])
      end

      table = @tables[from_tbl]? || raise DB::Error.new("no such table: #{from_tbl}")
      schema = table.schema

      # Filter rows
      filtered = table.rows.select do |row|
        if where = stmt.where_expr
          truthy?(eval_expr(where, row, schema, binder))
        else
          true
        end
      end

      # Aggregate: SELECT COUNT(*), MAX(col), MIN(col), SUM(col)
      if is_aggregate_select?(stmt)
        sc_expr = stmt.sel_cols[0].expr.as(AST::FnCall)
        col_name = sel_col_name(stmt.sel_cols[0])
        agg_val = compute_aggregate(sc_expr, filtered, schema, binder)
        return QueryResult.new([col_name], [[agg_val]])
      end

      # EXISTS: SELECT EXISTS(SELECT 1 FROM ...)
      if stmt.sel_cols.size == 1
        if (sc_expr = stmt.sel_cols[0].expr).is_a?(AST::FnCall) && sc_expr.fn == "EXISTS"
          if (arg = sc_expr.args[0]?).is_a?(AST::Subquery)
            sub_result = exec_select(arg.stmt, binder)
            exists_val = sub_result.is_a?(QueryResult) && !sub_result.rows.empty? ? 1_i64 : 0_i64
            return QueryResult.new(["EXISTS(...)"], [[exists_val.as(Value)]])
          end
        end
      end

      # ORDER BY
      unless stmt.order_by.empty?
        stmt.order_by.each do |col_ref, asc|
          col_idx = schema.col_index(col_ref.col)
          filtered = filtered.sort do |a, b|
            cmp = compare_values(a[col_idx], b[col_idx])
            asc ? cmp : -cmp
          end
        end
      end

      # LIMIT / OFFSET
      if limit_expr = stmt.limit_expr
        limit = to_i64(eval_expr(limit_expr, [] of Value, nil, binder))
        offset = if off_expr = stmt.offset_expr
          to_i64(eval_expr(off_expr, [] of Value, nil, binder)).to_i
        else
          0
        end
        filtered = filtered[offset, limit.to_i] || [] of Row
      end

      # Project columns
      col_names, rows = project_cols(stmt.sel_cols, filtered, schema, binder)
      QueryResult.new(col_names, rows)
    end

    private def compute_aggregate(fn : AST::FnCall, rows : Array(Row), schema : TableSchema, binder : ParamBinder) : Value
      case fn.fn
      when "COUNT"
        rows.size.to_i64.as(Value)
      when "MAX"
        if arg = fn.args[0]?
          vals = rows.map { |r| eval_expr(arg, r, schema, binder) }.compact
          vals.max_by? { |v| compare_values(v, vals[0]) }
        else
          nil
        end
      when "MIN"
        if arg = fn.args[0]?
          vals = rows.map { |r| eval_expr(arg, r, schema, binder) }.compact
          vals.min_by? { |v| compare_values(v, vals[0]) }
        else
          nil
        end
      when "SUM"
        if arg = fn.args[0]?
          vals = rows.map { |r| eval_expr(arg, r, schema, binder) }
          sum = vals.reduce(0_i64.as(Value)) do |acc, v|
            case {acc, v}
            when {Int64, Int64}     then (acc + v).as(Value)
            when {Float64, Float64} then (acc + v).as(Value)
            when {Int64, Float64}   then (acc.to_f64 + v).as(Value)
            when {Float64, Int64}   then (acc + v.to_f64).as(Value)
            else acc
            end
          end
          sum
        else
          nil
        end
      else
        nil
      end
    end

    private def is_aggregate_select?(stmt : AST::Select) : Bool
      return false unless stmt.sel_cols.size == 1
      expr = stmt.sel_cols[0].expr
      return false unless expr.is_a?(AST::FnCall)
      expr.fn == "COUNT" || expr.fn == "MAX" || expr.fn == "MIN" || expr.fn == "SUM"
    end

    private def project_cols(
      sel_cols : Array(AST::SelCol),
      rows : Array(Row),
      schema : TableSchema,
      binder : ParamBinder
    ) : {Array(String), Array(Row)}
      col_names = sel_cols.map { |sc| sel_col_name(sc) }

      result_rows = rows.map do |row|
        sel_cols.flat_map do |sc|
          if sc.expr.is_a?(AST::Star)
            row.dup
          else
            [eval_expr(sc.expr, row, schema, binder)]
          end
        end
      end

      if sel_cols.size == 1 && sel_cols[0].expr.is_a?(AST::Star)
        col_names = schema.cols.map(&.name)
      end

      {col_names, result_rows}
    end

    private def sel_col_name(sc : AST::SelCol) : String
      sc.alias_name || expr_to_col_name(sc.expr)
    end

    private def expr_to_col_name(expr : AST::Expr) : String
      case expr
      when AST::ColRef  then expr.col
      when AST::FnCall  then "#{expr.fn}(#{expr.args.map { |a| expr_to_col_name(a) }.join(",")})"
      when AST::Star    then "*"
      when AST::Lit     then expr.val.inspect
      else                   "?"
      end
    end

    # ── UPDATE ────────────────────────────────────────────────────────────────

    private def exec_update(stmt : AST::Update, binder : ParamBinder) : ExecuteResult
      table = @tables[stmt.tbl]? || raise DB::Error.new("no such table: #{stmt.tbl}")
      schema = table.schema
      rows_affected = 0_i64

      table.rows.each_with_index do |row, idx|
        matches = if where = stmt.where_expr
          truthy?(eval_expr(where, row, schema, binder))
        else
          true
        end
        next unless matches

        new_row = row.dup
        stmt.assignments.each do |col_name, val_expr|
          col_idx = schema.col_index(col_name)
          new_row[col_idx] = eval_expr(val_expr, row, schema, binder)
        end
        table.rows[idx] = new_row
        rows_affected += 1
      end

      ExecResult.new(rows_affected, @last_insert_rowid)
    end

    # ── DELETE ────────────────────────────────────────────────────────────────

    private def exec_delete(stmt : AST::Delete, binder : ParamBinder) : ExecuteResult
      table = @tables[stmt.tbl]? || raise DB::Error.new("no such table: #{stmt.tbl}")
      schema = table.schema
      rows_affected = 0_i64

      table.rows.reject! do |row|
        matches = if where = stmt.where_expr
          truthy?(eval_expr(where, row, schema, binder))
        else
          true
        end
        if matches
          rows_affected += 1
          true
        else
          false
        end
      end

      ExecResult.new(rows_affected, @last_insert_rowid)
    end

    # ── DROP TABLE ─────────────────────────────────────────────────────────────

    private def exec_drop_table(stmt : AST::DropTable, binder : ParamBinder) : ExecuteResult
      if stmt.if_exists
        @tables.delete(stmt.tbl)
      else
        @tables.delete(stmt.tbl) || raise DB::Error.new("no such table: #{stmt.tbl}")
      end
      ExecResult.new(0_i64, 0_i64)
    end

    # ── Expression evaluator ──────────────────────────────────────────────────

    private def eval_expr(
      expr : AST::Expr,
      row : Row,
      schema : TableSchema?,
      binder : ParamBinder
    ) : Value
      case expr
      when AST::Lit    then expr.val
      when AST::Param  then binder.get(expr.idx)
      when AST::ColRef then eval_col_ref(expr, row, schema)
      when AST::BinOp  then eval_binop(expr, row, schema, binder)
      when AST::IsNull then eval_is_null(expr, row, schema, binder)
      when AST::FnCall then eval_fn_call(expr, row, schema, binder)
      when AST::Star   then nil  # used only in COUNT(*); the caller handles it
      when AST::Subquery
        result = exec_select(expr.stmt, binder)
        if result.is_a?(QueryResult)
          result.rows.first?.try(&.first?) || nil
        else
          nil
        end
      else
        raise DB::Error.new("unsupported expr: #{expr.class}")
      end
    end

    private def eval_col_ref(expr : AST::ColRef, row : Row, schema : TableSchema?) : Value
      # SQLite pseudo-columns / built-in constants
      case expr.col.upcase
      when "CURRENT_TIMESTAMP"
        return Time.utc.to_s("%F %H:%M:%S").as(Value)
      when "CURRENT_DATE"
        return Time.utc.to_s("%F").as(Value)
      when "CURRENT_TIME"
        return Time.utc.to_s("%H:%M:%S").as(Value)
      end
      # SQLite fallback: a double-quoted "identifier" that can't be resolved as a
      # column is treated as a string literal (same behaviour as SQLite's SQLITE_DQS).
      if expr.quoted
        if s = schema
          idx = s.cols.index { |c| c.name == expr.col }
          return idx ? row[idx] : expr.col.as(Value)
        else
          return expr.col.as(Value)
        end
      end
      s = schema || raise DB::Error.new("column reference requires a FROM clause")
      idx = s.col_index(expr.col)
      row[idx]
    end

    private def eval_binop(
      expr : AST::BinOp,
      row : Row,
      schema : TableSchema?,
      binder : ParamBinder
    ) : Value
      case expr.op
      when AST::BinOp::Op::And
        l = eval_expr(expr.left, row, schema, binder)
        return false.as(Value) unless truthy?(l)
        eval_expr(expr.right, row, schema, binder)
      when AST::BinOp::Op::Or
        l = eval_expr(expr.left, row, schema, binder)
        return l if truthy?(l)
        eval_expr(expr.right, row, schema, binder)
      else
        l = eval_expr(expr.left, row, schema, binder)
        r = eval_expr(expr.right, row, schema, binder)
        cmp_result(expr.op, l, r)
      end
    end

    private def cmp_result(op : AST::BinOp::Op, l : Value, r : Value) : Value
      cmp = compare_values(l, r)
      result = case op
      when AST::BinOp::Op::Eq then cmp == 0
      when AST::BinOp::Op::Ne then cmp != 0
      when AST::BinOp::Op::Lt then cmp < 0
      when AST::BinOp::Op::Gt then cmp > 0
      when AST::BinOp::Op::Le then cmp <= 0
      when AST::BinOp::Op::Ge then cmp >= 0
      else false
      end
      result.as(Value)
    end

    private def eval_is_null(
      expr : AST::IsNull,
      row : Row,
      schema : TableSchema?,
      binder : ParamBinder
    ) : Value
      val = eval_expr(expr.expr, row, schema, binder)
      (expr.negated ? !val.nil? : val.nil?).as(Value)
    end

    private def eval_fn_call(
      expr : AST::FnCall,
      row : Row,
      schema : TableSchema?,
      binder : ParamBinder
    ) : Value
      case expr.fn
      when "LAST_INSERT_ROWID"
        @last_insert_rowid.as(Value)
      when "COUNT"
        # Evaluated differently in exec_select; here return nil sentinel.
        nil
      when "EXISTS"
        if (arg = expr.args[0]?).is_a?(AST::Subquery)
          result = exec_select(arg.stmt, binder)
          (result.is_a?(QueryResult) && !result.rows.empty? ? 1_i64 : 0_i64).as(Value)
        else
          nil
        end
      when "MAX"
        nil  # aggregate — handled by caller
      when "CAST"
        if arg = expr.args[0]?
          eval_expr(arg, row, schema, binder)
        else
          nil
        end
      else
        raise DB::Error.new("unknown function: #{expr.fn}")
      end
    end

    # ── Value utilities ───────────────────────────────────────────────────────

    private def truthy?(v : Value) : Bool
      case v
      when Nil   then false
      when Bool  then v
      when Int64 then v != 0
      when Float64 then v != 0.0
      when String then !v.empty?
      else true
      end
    end

    # Returns negative/zero/positive for l <=> r.  NULL sorts before everything.
    private def compare_values(l : Value, r : Value) : Int32
      return 0  if l.nil? && r.nil?
      return -1 if l.nil?
      return 1  if r.nil?

      case l
      when Int64
        case r
        when Int64   then (l <=> r) || 0
        when Float64 then (l.to_f64 <=> r) || 0
        else              (l.to_s <=> r.to_s) || 0
        end
      when Float64
        case r
        when Float64 then (l <=> r) || 0
        when Int64   then (l <=> r.to_f64) || 0
        else              (l.to_s <=> r.to_s) || 0
        end
      when String
        r.is_a?(String) ? ((l <=> r) || 0) : ((l <=> r.to_s) || 0)
      when Bool
        r.is_a?(Bool) ? (((l ? 1 : 0) <=> (r ? 1 : 0)) || 0) : 0
      else
        0
      end
    end

    private def to_i64(v : Value) : Int64
      case v
      when Int64   then v
      when Float64 then v.to_i64
      when String  then v.to_i64
      else 0_i64
      end
    end

    # ── Deep copy ─────────────────────────────────────────────────────────────

    private def deep_copy_tables : Hash(String, Table)
      result = Hash(String, Table).new
      @tables.each { |k, v| result[k] = v.deep_copy }
      result
    end
  end
end
