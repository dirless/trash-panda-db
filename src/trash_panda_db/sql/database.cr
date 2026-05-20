require "../sql/value"
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

  class ColSchema
    getter name : String
    getter type_str : String
    getter not_null : Bool
    def initialize(@name : String, type_str : String, @not_null : Bool)
      @type_str = type_str.upcase
    end
  end

  class TableSchema
    getter name : String
    getter cols : Array(ColSchema)
    getter pk_idx : Int32?
    getter auto_pk : Bool
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

  private class Snapshot
    getter tables : Hash(String, Table)
    getter last_insert_rowid : Int64
    def initialize(@tables : Hash(String, Table), @last_insert_rowid : Int64); end
  end

  class ParamBinder
    def initialize(@args : Array(Value)); end
    def get(idx : Int32) : Value
      raise DB::Error.new("parameter index #{idx} out of range (have #{@args.size})") if idx >= @args.size
      @args[idx]
    end
  end

  class Database
    getter tables : Hash(String, Table)
    getter btrees : Hash(String, Storage::BTree)
    @last_insert_rowid : Int64
    @tx_stack : Array(Snapshot)
    @committed_tables : Hash(String, Table)?
    @mutex : Mutex
    @pager : Storage::Pager?
    @tx_depth : Int32

    def initialize(@pager : Storage::Pager? = nil)
      @tables = Hash(String, Table).new
      @btrees = Hash(String, Storage::BTree).new
      @committed_tables = nil
      @last_insert_rowid = 0_i64
      @tx_stack = Array(Snapshot).new
      @tx_depth = 0_i32
      @mutex = Mutex.new(:reentrant)
    end

    def load_catalog(pager : Storage::Pager) : Nil
      @pager = pager
      return if pager.page_count < Storage::CATALOG_PAGE
      entries = Storage::Catalog.load(pager)
      entries.each do |name, info|
        @tables[name] = Table.new(info[:schema], [] of Row, info[:next_rowid])
        @btrees[name] = Storage::BTree.new(pager, info[:root_page])
      end
    end

    private def save_catalog : Nil
      return unless pager = @pager
      Storage::Catalog.save(pager, @tables, @btrees)
    end

    def in_transaction? : Bool
      @tx_depth > 0
    end

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

    protected def set_table(name : String, table : Table) : Nil
      @mutex.synchronize { @tables[name] = table }
    end

    def begin_transaction : Nil
      @mutex.synchronize do
        @committed_tables = deep_copy_tables if @tx_stack.empty?
        @tx_stack << Snapshot.new(deep_copy_tables, @last_insert_rowid)
        @tx_depth += 1
      end
    end

    def commit_transaction : Nil
      @mutex.synchronize do
        @tx_stack.pop?
        @committed_tables = nil if @tx_stack.empty?
        @tx_depth -= 1
        if @tx_depth == 0
          pager = @pager
          if pager
            save_catalog
            pager.commit unless in_transaction?
          end
        end
      end
    end

    def rollback_transaction : Nil
      @mutex.synchronize do
        if snap = @tx_stack.pop?
          @tables = snap.tables
          @last_insert_rowid = snap.last_insert_rowid
        end
        @committed_tables = nil if @tx_stack.empty?
        @tx_depth -= 1
        if @pager && @tx_depth == 0
          @pager.not_nil!.rollback
          load_catalog(@pager.not_nil!)
        end
      end
    end

    def create_savepoint(name : String) : Nil
      @mutex.synchronize do
        @tx_stack << Snapshot.new(deep_copy_tables, @last_insert_rowid)
        @tx_depth += 1
        @pager.try(&.wal.push_savepoint(name))
      end
    end

    def release_savepoint(name : String) : Nil
      @mutex.synchronize do
        @tx_stack.pop?
        @tx_depth -= 1
        @pager.try(&.wal.release_savepoint(name))
      end
    end

    def rollback_to_savepoint(name : String) : Nil
      @mutex.synchronize do
        if snap = @tx_stack.pop?
          @tables = snap.tables.transform_values(&.deep_copy)
          @last_insert_rowid = snap.last_insert_rowid
        end
        @tx_depth -= 1
        if pager = @pager
          pager.wal.pop_savepoint(name)
          load_catalog(pager) if @tx_depth == 0
        end
      end
    end

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

    private def exec_create_table(stmt : AST::CreateTable, binder : ParamBinder) : ExecResult
      name = stmt.tbl
      if @tables.has_key?(name)
        return ExecResult.new(0_i64, 0_i64) if stmt.if_not_exists
        raise DB::Error.new("table #{name} already exists")
      end

      col_schemas = stmt.col_defs.map { |c| ColSchema.new(c.name, c.type_str, c.not_null) }
      pk_names = stmt.table_pk.dup
      stmt.col_defs.each { |c| pk_names << c.name if c.pk }
      pk_names.uniq!
      schema = TableSchema.new(name, col_schemas, pk_names)
      @tables[name] = Table.new(schema)

      if pager = @pager
        root_page = Storage::BTree.create(pager)
        @btrees[name] = Storage::BTree.new(pager, root_page)
        save_catalog
        pager.commit unless in_transaction?
      end

      ExecResult.new(0_i64, 0_i64)
    end

    private def exec_insert(stmt : AST::Insert, binder : ParamBinder) : ExecResult
      table = @tables[stmt.tbl]? || raise DB::Error.new("no such table: #{stmt.tbl}")
      schema = table.schema
      rows_affected = 0_i64
      codec = Storage::RowCodec

      stmt.value_rows.each do |val_exprs|
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

        rowid = if pk_idx = schema.pk_idx
          v = row[pk_idx]
          v.is_a?(Int64) ? v : table.next_rowid
        else
          table.next_rowid
        end

        if bt = @btrees[stmt.tbl]?
          key = codec.encode_key(rowid)
          val = codec.encode(row)
          case stmt.conflict
          when AST::Insert::Conflict::Replace
            if existing_idx = find_row_index(table, rowid)
              bt.update(key, val)
              table.rows[existing_idx] = row
            else
              bt.insert(key, val)
              table.rows << row
              table.next_rowid = rowid + 1 if rowid >= table.next_rowid
            end
          when AST::Insert::Conflict::Ignore
            unless bt.search(key)
              bt.insert(key, val)
              table.rows << row
              table.next_rowid = rowid + 1 if rowid >= table.next_rowid
            end
          else
            if bt.search(key)
              pk_col_name = if pk_idx = schema.pk_idx
                schema.cols[pk_idx].name
              else
                "?"
              end
              raise DB::Error.new("UNIQUE constraint failed: #{schema.name}.#{pk_col_name}")
            end
            bt.insert(key, val)
            table.rows << row
            table.next_rowid = rowid + 1 if rowid >= table.next_rowid
          end
        else
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
                pk_col_name = if pk_idx = schema.pk_idx
                  schema.cols[pk_idx].name
                else
                  "?"
                end
                raise DB::Error.new("UNIQUE constraint failed: #{schema.name}.#{pk_col_name}")
              end
              table.rows << row
            end
          else
            table.rows << row
          end
        end

        @last_insert_rowid = rowid
        rows_affected += 1
      end

      save_catalog if @pager && @btrees[stmt.tbl]?
      ExecResult.new(rows_affected, @last_insert_rowid)
    end

    private def exec_select(stmt : AST::Select, binder : ParamBinder) : ExecuteResult
      from_tbl = stmt.from_tbl

      if from_tbl.nil? && stmt.sel_cols.size == 1
        col = stmt.sel_cols[0]
        if (expr = col.expr).is_a?(AST::FnCall) && expr.fn == "LAST_INSERT_ROWID"
          return QueryResult.new(["LAST_INSERT_ROWID()"], [[@last_insert_rowid.as(Value)]])
        end
      end

      if from_tbl.nil?
        col_names = stmt.sel_cols.map { |sc| sel_col_name(sc) }
        result_row = stmt.sel_cols.map { |sc| eval_expr(sc.expr, [] of Value, nil, binder) }
        return QueryResult.new(col_names, [result_row])
      end

      table = @tables[from_tbl]? || raise DB::Error.new("no such table: #{from_tbl}")
      schema = table.schema

      # Only use btree scan when no one else is in a transaction
      # (committed_tables snapshots don't cover the btree, so we fall
      # back to table.rows for transaction isolation).
      if (bt = @btrees[from_tbl]?) && @committed_tables.nil?
        codec = Storage::RowCodec

        # Handle aggregate queries without materializing all rows.
        if is_aggregate_select?(stmt)
          sc_expr = stmt.sel_cols[0].expr.as(AST::FnCall)
          col_name = sel_col_name(stmt.sel_cols[0])
          agg_val = compute_aggregate_scan(bt, sc_expr, schema, binder, stmt.where_expr)
          return QueryResult.new([col_name], [[agg_val]])
        end

        rows = [] of Row
        bt.scan do |k, v|
          row = codec.decode(v)
          if where = stmt.where_expr
            next unless truthy?(eval_expr(where, row, schema, binder))
          end
          rows << row
        end

        unless stmt.order_by.empty?
          stmt.order_by.each do |col_ref, asc|
            col_idx = schema.col_index(col_ref.col)
            rows = rows.sort do |a, b|
              cmp = compare_values(a[col_idx], b[col_idx])
              asc ? cmp : -cmp
            end
          end
        end

        if limit_expr = stmt.limit_expr
          limit = to_i64(eval_expr(limit_expr, [] of Value, nil, binder))
          offset = if off_expr = stmt.offset_expr
            to_i64(eval_expr(off_expr, [] of Value, nil, binder)).to_i
          else
            0
          end
          rows = rows[offset, limit.to_i] || [] of Row
        end

        col_names, result_rows = project_cols(stmt.sel_cols, rows, schema, binder)
        return QueryResult.new(col_names, result_rows)
      end

      filtered = table.rows.select do |row|
        if where = stmt.where_expr
          truthy?(eval_expr(where, row, schema, binder))
        else
          true
        end
      end

      if is_aggregate_select?(stmt)
        sc_expr = stmt.sel_cols[0].expr.as(AST::FnCall)
        col_name = sel_col_name(stmt.sel_cols[0])
        agg_val = compute_aggregate(sc_expr, filtered, schema, binder)
        return QueryResult.new([col_name], [[agg_val]])
      end

      if stmt.sel_cols.size == 1
        if (sc_expr = stmt.sel_cols[0].expr).is_a?(AST::FnCall) && sc_expr.fn == "EXISTS"
          if (arg = sc_expr.args[0]?).is_a?(AST::Subquery)
            sub_result = exec_select(arg.stmt, binder)
            exists_val = sub_result.is_a?(QueryResult) && !sub_result.rows.empty? ? 1_i64 : 0_i64
            return QueryResult.new(["EXISTS(...)"], [[exists_val.as(Value)]])
          end
        end
      end

      unless stmt.order_by.empty?
        stmt.order_by.each do |col_ref, asc|
          col_idx = schema.col_index(col_ref.col)
          filtered = filtered.sort do |a, b|
            cmp = compare_values(a[col_idx], b[col_idx])
            asc ? cmp : -cmp
          end
        end
      end

      if limit_expr = stmt.limit_expr
        limit = to_i64(eval_expr(limit_expr, [] of Value, nil, binder))
        offset = if off_expr = stmt.offset_expr
          to_i64(eval_expr(off_expr, [] of Value, nil, binder)).to_i
        else
          0
        end
        filtered = filtered[offset, limit.to_i] || [] of Row
      end

      col_names, rows = project_cols(stmt.sel_cols, filtered, schema, binder)
      QueryResult.new(col_names, rows)
    end

    private def exec_update(stmt : AST::Update, binder : ParamBinder) : ExecResult
      table = @tables[stmt.tbl]? || raise DB::Error.new("no such table: #{stmt.tbl}")
      schema = table.schema
      rows_affected = 0_i64

      if bt = @btrees[stmt.tbl]?
        codec = Storage::RowCodec
        to_update = [] of Tuple(Int64, Row)
        bt.scan do |k, v|
          row = codec.decode(v)
          rowid = codec.decode_key(k)
          if where = stmt.where_expr
            next unless truthy?(eval_expr(where, row, schema, binder))
          end
          new_row = row.dup
          stmt.assignments.each do |col_name, val_expr|
            col_idx = schema.col_index(col_name)
            new_row[col_idx] = eval_expr(val_expr, row, schema, binder)
          end
          to_update << {rowid, new_row}
        end
        to_update.each do |rowid, new_row|
          key = codec.encode_key(rowid)
          bt.update(key, codec.encode(new_row))
          if i = find_row_index(table, rowid)
            table.rows[i] = new_row
          end
          rows_affected += 1
        end
      else
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
      end

      save_catalog if @pager && @btrees[stmt.tbl]?
      ExecResult.new(rows_affected, @last_insert_rowid)
    end

    private def exec_delete(stmt : AST::Delete, binder : ParamBinder) : ExecResult
      table = @tables[stmt.tbl]? || raise DB::Error.new("no such table: #{stmt.tbl}")
      schema = table.schema
      rows_affected = 0_i64

      if bt = @btrees[stmt.tbl]?
        codec = Storage::RowCodec
        to_delete = [] of Bytes
        bt.scan do |k, v|
          row = codec.decode(v)
          if where = stmt.where_expr
            next unless truthy?(eval_expr(where, row, schema, binder))
          end
          to_delete << k.dup
        end
        to_delete.each do |k|
          rowid = codec.decode_key(k)
          bt.delete(k)
          if i = find_row_index(table, rowid)
            table.rows.delete_at(i)
          end
          rows_affected += 1
        end
      else
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
      end

      save_catalog if @pager && @btrees[stmt.tbl]?
      ExecResult.new(rows_affected, @last_insert_rowid)
    end

    private def exec_drop_table(stmt : AST::DropTable, binder : ParamBinder) : ExecResult
      if stmt.if_exists
        @tables.delete(stmt.tbl)
        @btrees.delete(stmt.tbl)
      else
        @tables.delete(stmt.tbl) || raise DB::Error.new("no such table: #{stmt.tbl}")
        @btrees.delete(stmt.tbl)
      end
      if pager = @pager
        save_catalog
        pager.commit unless in_transaction?
      end
      ExecResult.new(0_i64, 0_i64)
    end

    private def compute_aggregate_scan(bt : Storage::BTree, fn : AST::FnCall, schema : TableSchema, binder : ParamBinder, where_expr : AST::Expr?) : Value
      codec = Storage::RowCodec
      case fn.fn
      when "COUNT"
        if (arg = fn.args[0]?) && !arg.is_a?(AST::Star)
          count_scan(bt, codec, schema, binder, where_expr, arg)
        else
          count_star_scan(bt, codec, schema, binder, where_expr)
        end
      when "MAX", "MIN"
        return nil unless (arg = fn.args[0]?)
        best : Value = nil
        bt.scan do |k, v|
          row = codec.decode(v)
          next if where_expr && !truthy?(eval_expr(where_expr, row, schema, binder))
          val = eval_expr(arg, row, schema, binder)
          next if val.nil?
          if best.nil? || (fn.fn == "MAX" ? compare_values(best, val) < 0 : compare_values(best, val) > 0)
            best = val
          end
        end
        best
      when "SUM"
        return nil unless (arg = fn.args[0]?)
        acc : Value = 0_i64
        bt.scan do |k, v|
          row = codec.decode(v)
          next if where_expr && !truthy?(eval_expr(where_expr, row, schema, binder))
          val = eval_expr(arg, row, schema, binder)
          next if val.nil?
          acc = case {acc, val}
          when {Int64, Int64}     then (acc + val).as(Value)
          when {Float64, Float64} then (acc + val).as(Value)
          when {Int64, Float64}   then (acc.to_f64 + val).as(Value)
          when {Float64, Int64}   then (acc + val.to_f64).as(Value)
          else acc
          end
        end
        acc
      else
        nil
      end
    end

    private def count_scan(bt : Storage::BTree, codec : Storage::RowCodec.class, schema : TableSchema, binder : ParamBinder, where_expr : AST::Expr?, arg : AST::Expr) : Value
      count = 0_i64
      bt.scan do |k, v|
        row = codec.decode(v)
        next if where_expr && !truthy?(eval_expr(where_expr, row, schema, binder))
        val = eval_expr(arg, row, schema, binder)
        count += 1 unless val.nil?
      end
      count.as(Value)
    end

    private def count_star_scan(bt : Storage::BTree, codec : Storage::RowCodec.class, schema : TableSchema, binder : ParamBinder, where_expr : AST::Expr?) : Value
      count = 0_i64
      bt.scan do |k, v|
        row = codec.decode(v)
        next if where_expr && !truthy?(eval_expr(where_expr, row, schema, binder))
        count += 1
      end
      count.as(Value)
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
          vals.reduce(0_i64.as(Value)) do |acc, v|
            case {acc, v}
            when {Int64, Int64}     then (acc + v).as(Value)
            when {Float64, Float64} then (acc + v).as(Value)
            when {Int64, Float64}   then (acc.to_f64 + v).as(Value)
            when {Float64, Int64}   then (acc + v.to_f64).as(Value)
            else acc
            end
          end
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

    private def eval_expr(expr : AST::Expr, row : Row, schema : TableSchema?, binder : ParamBinder) : Value
      case expr
      when AST::Lit    then expr.val
      when AST::Param  then binder.get(expr.idx)
      when AST::ColRef then eval_col_ref(expr, row, schema)
      when AST::BinOp  then eval_binop(expr, row, schema, binder)
      when AST::IsNull then eval_is_null(expr, row, schema, binder)
      when AST::FnCall then eval_fn_call(expr, row, schema, binder)
      when AST::Star   then nil
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
      case expr.col.upcase
      when "CURRENT_TIMESTAMP"
        return Time.utc.to_s("%F %H:%M:%S").as(Value)
      when "CURRENT_DATE"
        return Time.utc.to_s("%F").as(Value)
      when "CURRENT_TIME"
        return Time.utc.to_s("%H:%M:%S").as(Value)
      end
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

    private def eval_binop(expr : AST::BinOp, row : Row, schema : TableSchema?, binder : ParamBinder) : Value
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

    private def eval_is_null(expr : AST::IsNull, row : Row, schema : TableSchema?, binder : ParamBinder) : Value
      val = eval_expr(expr.expr, row, schema, binder)
      (expr.negated ? !val.nil? : val.nil?).as(Value)
    end

    private def eval_fn_call(expr : AST::FnCall, row : Row, schema : TableSchema?, binder : ParamBinder) : Value
      case expr.fn
      when "LAST_INSERT_ROWID"
        @last_insert_rowid.as(Value)
      when "COUNT"
        nil
      when "EXISTS"
        if (arg = expr.args[0]?).is_a?(AST::Subquery)
          result = exec_select(arg.stmt, binder)
          (result.is_a?(QueryResult) && !result.rows.empty? ? 1_i64 : 0_i64).as(Value)
        else
          nil
        end
      when "MAX"
        nil
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

    private def find_row_index(table : Table, rowid : Int64) : Int32?
      pk_idx = table.schema.pk_idx
      return nil unless pk_idx
      table.rows.index { |r| r[pk_idx] == rowid }
    end

    private def deep_copy_tables : Hash(String, Table)
      result = Hash(String, Table).new
      @tables.each { |k, v| result[k] = v.deep_copy }
      result
    end
  end
end
