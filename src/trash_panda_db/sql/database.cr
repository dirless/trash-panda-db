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
    getter default_sql : String?
    def initialize(@name : String, type_str : String, @not_null : Bool, @default_sql : String? = nil)
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
        @cols.index { |c| c.name.ends_with?(".#{name}") } ||
        raise DB::Error.new("no such column: #{name}")
    end
  end

  class Table
    getter schema : TableSchema
    property next_rowid : Int64
    def initialize(@schema : TableSchema, @next_rowid : Int64 = 1_i64); end
    def deep_copy : Table
      Table.new(@schema, @next_rowid)
    end
  end

  private class Snapshot
    getter tables : Hash(String, Table)
    getter last_insert_rowid : Int64
    getter indexes : Hash(String, Storage::IndexMeta)
    getter col_indexes : Hash(String, Array(String))
    def initialize(@tables, @last_insert_rowid, @indexes, @col_indexes); end
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
    getter pager : Storage::Pager
    @indexes : Hash(String, Storage::IndexMeta)
    @index_btrees : Hash(String, Storage::BTree)
    @col_indexes : Hash(String, Array(String))
    @last_insert_rowid : Int64
    @tx_stack : Array(Snapshot)
    @committed_tables : Hash(String, Table)?
    @mutex : Mutex
    @pager : Storage::Pager
    @tx_depth : Int32
    @raw_tx_fiber : Fiber?

    # Metrics counters (lock-free atomics)
    @queries_total      = Atomic(Int64).new(0_i64)
    @writes_total       = Atomic(Int64).new(0_i64)
    @slow_queries_total = Atomic(Int64).new(0_i64)

    def queries_total      : Int64; @queries_total.get; end
    def writes_total       : Int64; @writes_total.get; end
    def slow_queries_total : Int64; @slow_queries_total.get; end

    def initialize(@pager : Storage::Pager = Storage::Pager.new(nil))
      @tables = Hash(String, Table).new
      @btrees = Hash(String, Storage::BTree).new
      @indexes = Hash(String, Storage::IndexMeta).new
      @index_btrees = Hash(String, Storage::BTree).new
      @col_indexes = Hash(String, Array(String)).new
      @committed_tables = nil
      @last_insert_rowid = 0_i64
      @tx_stack = Array(Snapshot).new
      @tx_depth = 0_i32
      @raw_tx_fiber = nil
      @mutex = Mutex.new(:reentrant)
      load_catalog
    end

    private def load_catalog : Nil
      @tables.clear
      @btrees.clear
      @indexes.clear
      @index_btrees.clear
      @col_indexes.clear
      return if @pager.page_count < Storage::CATALOG_PAGE
      result = Storage::Catalog.load(@pager)
      result[:tables].each do |name, info|
        @tables[name] = Table.new(info[:schema], info[:next_rowid])
        @btrees[name] = Storage::BTree.new(@pager, info[:root_page])
      end
      result[:indexes].each do |name, meta|
        @indexes[name] = meta
        @index_btrees[name] = Storage::BTree.new(@pager, meta.root_page)
        col_key = "#{meta.table}.#{meta.cols[0]}"
        (@col_indexes[col_key] ||= [] of String) << name
      end
    end

    private def save_catalog : Nil
      @index_btrees.each do |name, bt|
        @indexes[name]?.try { |m| m.root_page = bt.root_page }
      end
      Storage::Catalog.save(@pager, @tables, @btrees, @indexes)
    end

    def in_transaction? : Bool
      @tx_depth > 0
    end

    private def slow_query_ms : Int64
      ENV["TPDB_SLOW_QUERY_MS"]?.try(&.to_i64?) || 100_i64
    end

    def execute(sql : String, args : Array(Value), in_txn : Bool = false) : ExecuteResult
      @queries_total.add(1)
      t0 = Time.instant
      exec_out = @mutex.synchronize do
        stmt = Parser.new(Lexer.new(sql).tokenize).parse
        binder = ParamBinder.new(args)
        # committed_only: true only for concurrent readers while a transaction is
        # active. The transaction owner is identified either by crystal-db's managed
        # tx flag (in_txn) or by being the same fiber that issued a raw SQL BEGIN.
        owns_tx = in_txn || Fiber.current == @raw_tx_fiber
        committed_only = !owns_tx && !@tx_stack.empty?
        res = exec_stmt(stmt, binder, committed_only)
        # Track raw SQL transaction ownership by fiber (managed txns use perform_begin_transaction).
        case stmt
        when AST::Begin
          @raw_tx_fiber = Fiber.current if @tx_stack.size == 1
        when AST::Commit, AST::Rollback
          @raw_tx_fiber = nil if @tx_stack.empty?
        when AST::Insert, AST::Update, AST::Delete,
             AST::CreateTable, AST::DropTable, AST::AlterTable,
             AST::CreateIndex, AST::DropIndex
          @writes_total.add(1)
        end
        res
      end
      ms = (Time.instant - t0).total_milliseconds
      if ms >= slow_query_ms
        @slow_queries_total.add(1)
        STDERR.puts "[SLOW] #{ms.round.to_i}ms  #{sql}"
      end
      exec_out
    end

    protected def set_table(name : String, table : Table) : Nil
      @mutex.synchronize { @tables[name] = table }
    end

    def begin_transaction : Nil
      @mutex.synchronize do
        @committed_tables = deep_copy_tables if @tx_stack.empty?
        @tx_stack << Snapshot.new(deep_copy_tables, @last_insert_rowid, @indexes.dup, @col_indexes.transform_values(&.dup))
        @tx_depth += 1
      end
    end

    def commit_transaction : Nil
      @mutex.synchronize do
        @tx_stack.pop?
        if @tx_stack.empty?
          @committed_tables = nil
          @raw_tx_fiber = nil
        end
        @tx_depth -= 1
        if @tx_depth == 0
          save_catalog
          @pager.commit unless in_transaction?
        end
      end
    end

    # Flush dirty pager pages to disk (WAL). Safe to call outside transactions.
    def commit_pager : Nil
      @mutex.synchronize do
        @pager.commit
      end
    end

    # Flush dirty pages to WAL, then merge WAL into the main file.
    # After this the main DB file is self-contained for snapshotting.
    def flush_and_checkpoint : Nil
      @mutex.synchronize do
        @pager.commit
        @pager.checkpoint
      end
    end

    # Thread-safe copy of the DB file for snapshotting.  Holds @mutex so a
    # concurrent checkpoint cannot write to the source file during the copy.
    def copy_db_file(dest : String) : Nil
      @mutex.synchronize do
        File.copy(@pager.path.not_nil!, dest)
        File.open(dest, "r") { |f| f.fsync }
      end
    end

    # Replace the pager's underlying file with a snapshot copy and reload.
    # Called when an InstallSnapshot restores the DB state on a follower.
    # Deletes the old WAL first so its stale committed frames don't overwrite
    # the snapshot data on replay.
    def replace_pager_from_file(path : String) : Nil
      @mutex.synchronize do
        db_path = @pager.path
        raise "pager has no file path" unless db_path
        @pager.close
        wal_path = db_path + "-wal"
        File.delete(wal_path) rescue nil
        File.copy(path, db_path)
        @pager = Storage::Pager.new(db_path)
        load_catalog
      end
    end

    # Discard the current pager and start fresh.  If file-backed, deletes the DB
    # file so replay_committed rebuilds from the Raft log without stale state.
    def recreate_pager! : Nil
      @mutex.synchronize do
        old_path = @pager.path
        @pager.close
        if old_path && File.exists?(old_path)
          wal_path = old_path + "-wal"
          File.delete(old_path) rescue nil
          File.delete(wal_path) rescue nil
        end
        @pager = Storage::Pager.new(old_path)
        load_catalog
      end
    end

    def rollback_transaction : Nil
      @mutex.synchronize do
        if snap = @tx_stack.pop?
          @tables = snap.tables
          @last_insert_rowid = snap.last_insert_rowid
          @indexes = snap.indexes
          @col_indexes = snap.col_indexes
        end
        if @tx_stack.empty?
          @committed_tables = nil
          @raw_tx_fiber = nil
        end
        @tx_depth -= 1
        if @tx_depth == 0
          @pager.rollback
          load_catalog
        end
      end
    end

    def create_savepoint(name : String) : Nil
      @mutex.synchronize do
        @tx_stack << Snapshot.new(deep_copy_tables, @last_insert_rowid, @indexes.dup, @col_indexes.transform_values(&.dup))
        @tx_depth += 1
        @pager.wal.push_savepoint(name)
      end
    end

    def release_savepoint(name : String) : Nil
      @mutex.synchronize do
        @tx_stack.pop?
        @tx_depth -= 1
        @pager.wal.release_savepoint(name)
      end
    end

    def rollback_to_savepoint(name : String) : Nil
      @mutex.synchronize do
        if snap = @tx_stack.pop?
          @tables = snap.tables.transform_values(&.deep_copy)
          @last_insert_rowid = snap.last_insert_rowid
          @indexes = snap.indexes.dup
          @col_indexes = snap.col_indexes.transform_values(&.dup)
        end
        @tx_depth -= 1
        @pager.wal.pop_savepoint(name)
        load_catalog if @tx_depth == 0
      end
    end

    private def exec_stmt(stmt : AST::Stmt, binder : ParamBinder, committed_only : Bool = false) : ExecuteResult
      case stmt
      when AST::CreateTable   then exec_create_table(stmt, binder)
      when AST::CreateIndex   then exec_create_index(stmt)
      when AST::AlterTable    then exec_alter_table(stmt, binder)
      when AST::Insert        then exec_insert(stmt, binder)
      when AST::Select        then exec_select(stmt, binder, committed_only)
      when AST::Update        then exec_update(stmt, binder)
      when AST::Delete        then exec_delete(stmt, binder)
      when AST::DropTable     then exec_drop_table(stmt, binder)
      when AST::DropIndex     then exec_drop_index(stmt)
      when AST::Explain       then exec_explain(stmt, binder)
      when AST::Vacuum        then exec_vacuum
      when AST::Pragma        then ExecResult.new(0_i64, 0_i64)
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

      col_schemas = stmt.col_defs.map { |c|
        ColSchema.new(c.name, c.type_str, c.not_null, c.default_expr.try { |e| expr_to_sql(e) })
      }
      pk_names = stmt.table_pk.dup
      stmt.col_defs.each { |c| pk_names << c.name if c.pk }
      pk_names.uniq!
      schema = TableSchema.new(name, col_schemas, pk_names)
      @tables[name] = Table.new(schema)

      root_page = Storage::BTree.create(@pager)
      @btrees[name] = Storage::BTree.new(@pager, root_page)

      # Auto-create implicit unique indexes for columns declared UNIQUE
      stmt.col_defs.each do |c|
        next unless c.unique && !c.pk  # PK is already unique via the btree key
        idx_name = "_uq_#{name}_#{c.name}"
        idx_root = Storage::BTree.create(@pager)
        meta = Storage::IndexMeta.new(idx_name, name, [c.name], idx_root, true)
        @indexes[idx_name] = meta
        @index_btrees[idx_name] = Storage::BTree.new(@pager, idx_root)
        col_key = "#{name}.#{c.name}"
        (@col_indexes[col_key] ||= [] of String) << idx_name
      end

      save_catalog
      @pager.commit unless in_transaction?

      ExecResult.new(0_i64, 0_i64)
    end

    private def exec_explain(stmt : AST::Explain, binder : ParamBinder) : QueryResult
      sel = stmt.stmt
      from_tbl = sel.from_tbl
      unless from_tbl
        return QueryResult.new(["QUERY PLAN"], [["Scan: no FROM clause".as(Value)]])
      end

      table = @tables[from_tbl]?
      unless table
        return QueryResult.new(["QUERY PLAN"], [["Error: no such table: #{from_tbl}".as(Value)]])
      end
      schema = table.schema
      bt = @btrees[from_tbl]? || return QueryResult.new(["QUERY PLAN"], [["Error: no btree for #{from_tbl}".as(Value)]])

      row_count = 0_i64
      bt.scan { row_count += 1 }

      plan_lines = Array(Array(Value)).new

      if sel.joins.any?
        join_desc = sel.joins.map { |j| "#{j.join_type} JOIN #{j.tbl}" }.join(", ")
        plan_lines << ["JOIN: #{from_tbl} with #{join_desc} (~#{row_count} rows each)".as(Value)]
      elsif pk_key = extract_pk_key(schema, sel.where_expr, binder)
        pk_col = schema.pk_idx ? schema.cols[schema.pk_idx.not_nil!].name : "rowid"
        plan_lines << ["PK lookup on #{from_tbl}.#{pk_col} (est. 1 row)".as(Value)]
      elsif idx_pair = extract_index_lookup(from_tbl, schema, sel.where_expr, binder)
        idx_bt, _ = idx_pair
        idx_name = @indexes.find { |n, m| m.table == from_tbl && @index_btrees[n]?.try(&.root_page) == idx_bt.root_page }.try(&.first) || "index"
        plan_lines << ["Index scan: #{idx_name} on #{from_tbl} (est. ~#{[row_count / 10 + 1, row_count].min} rows)".as(Value)]
      elsif between = extract_index_between(from_tbl, schema, sel.where_expr, binder)
        idx_bt, _, _, _, _ = between
        idx_name = @indexes.find { |n, m| m.table == from_tbl && @index_btrees[n]?.try(&.root_page) == idx_bt.root_page }.try(&.first) || "index"
        plan_lines << ["Index range scan (BETWEEN): #{idx_name} on #{from_tbl} (est. ~#{[row_count / 5 + 1, row_count].min} rows)".as(Value)]
      elsif range = extract_index_range(from_tbl, schema, sel.where_expr, binder)
        idx_bt, _, _ = range
        idx_name = @indexes.find { |n, m| m.table == from_tbl && @index_btrees[n]?.try(&.root_page) == idx_bt.root_page }.try(&.first) || "index"
        plan_lines << ["Index range scan: #{idx_name} on #{from_tbl} (est. ~#{[row_count / 2 + 1, row_count].min} rows)".as(Value)]
      else
        plan_lines << ["Full scan on #{from_tbl} (~#{row_count} rows)".as(Value)]
      end

      if sel.where_expr
        plan_lines << ["Filter: WHERE condition".as(Value)]
      end
      if sel.group_by.any?
        plan_lines << ["GroupBy: #{sel.group_by.size} expression(s)".as(Value)]
      end
      if sel.order_by.any?
        plan_lines << ["Sort: #{sel.order_by.map { |cr, asc| "#{cr.col} #{asc ? "ASC" : "DESC"}" }.join(", ")}".as(Value)]
      end
      if sel.limit_expr
        plan_lines << ["Limit".as(Value)]
      end

      QueryResult.new(["QUERY PLAN"], plan_lines)
    end

    private def exec_create_index(stmt : AST::CreateIndex) : ExecResult
      if @indexes.has_key?(stmt.name)
        return ExecResult.new(0_i64, 0_i64) if stmt.if_not_exists
        raise DB::Error.new("index #{stmt.name} already exists")
      end
      table = @tables[stmt.tbl]? || raise DB::Error.new("no such table: #{stmt.tbl}")
      schema = table.schema
      col_is = stmt.cols.map { |cn|
        schema.cols.index { |c| c.name == cn } || raise DB::Error.new("no such column: #{cn}")
      }

      root_page = Storage::BTree.create(@pager)
      idx_bt = Storage::BTree.new(@pager, root_page)
      meta = Storage::IndexMeta.new(stmt.name, stmt.tbl, stmt.cols, root_page, stmt.unique)
      @indexes[stmt.name] = meta
      @index_btrees[stmt.name] = idx_bt
      col_key = "#{stmt.tbl}.#{stmt.cols[0]}"
      (@col_indexes[col_key] ||= [] of String) << stmt.name

      bt = @btrees[stmt.tbl]? || raise DB::Error.new("no btree for table: #{stmt.tbl}")
      codec = Storage::RowCodec

      if stmt.unique
        seen = Hash(String, Nil).new
        bt.scan do |k, v|
          row = codec.decode(v)
          vals = col_is.map { |i| row[i] }
          next if vals.any?(&.nil?)
          key_str = vals.map(&.inspect).join(",")
          raise DB::Error.new("UNIQUE constraint failed: #{stmt.tbl}.(#{stmt.cols.join(",")})") if seen.has_key?(key_str)
          seen[key_str] = nil
        end
      end

      bt.scan do |k, v|
        row = codec.decode(v)
        rowid = codec.decode_key(k)
        vals = col_is.map { |i| row[i] }
        next if vals.any?(&.nil?)
        idx_bt.insert(codec.encode_index_key(vals, rowid), Bytes.new(0))
      end

      save_catalog
      @pager.commit unless in_transaction?
      ExecResult.new(0_i64, 0_i64)
    end

    private def exec_drop_index(stmt : AST::DropIndex) : ExecResult
      unless @indexes.has_key?(stmt.name)
        return ExecResult.new(0_i64, 0_i64) if stmt.if_exists
        raise DB::Error.new("no such index: #{stmt.name}")
      end
      meta = @indexes.delete(stmt.name).not_nil!
      if bt = @index_btrees.delete(stmt.name)
        bt.free_tree
      end
      col_key = "#{meta.table}.#{meta.cols[0]}"
      @col_indexes[col_key]?.try(&.delete(stmt.name))
      @col_indexes.delete(col_key) if @col_indexes[col_key]?.try(&.empty?)

      save_catalog
      @pager.commit unless in_transaction?
      ExecResult.new(0_i64, 0_i64)
    end

    private def exec_alter_table(stmt : AST::AlterTable, binder : ParamBinder) : ExecResult
      table = @tables[stmt.tbl]? || raise DB::Error.new("no such table: #{stmt.tbl}")
      schema = table.schema
      codec = Storage::RowCodec

      case cmd = stmt.cmd
      when AST::AlterAddColumn
        col_def = cmd.col_def
        raise DB::Error.new("column #{col_def.name} already exists") if schema.cols.any? { |c| c.name == col_def.name }
        raise DB::Error.new("PRIMARY KEY not allowed in ADD COLUMN") if col_def.pk

        new_col = ColSchema.new(col_def.name, col_def.type_str, col_def.not_null,
                                col_def.default_expr.try { |e| expr_to_sql(e) })

        # NOT NULL without a default is only valid if the table is empty
        bt = @btrees[stmt.tbl].not_nil!
        if new_col.not_null && new_col.default_sql.nil?
          has_rows = false
          bt.scan { has_rows = true; break }
          raise DB::Error.new("column \"#{new_col.name}\" of relation \"#{stmt.tbl}\" contains null values") if has_rows
        end

        new_cols = schema.cols + [new_col]
        pk_names = schema.pk_idx ? [schema.cols[schema.pk_idx.not_nil!].name] : [] of String
        new_schema = TableSchema.new(stmt.tbl, new_cols, pk_names)
        new_col_idx = new_cols.size - 1

        # Rewrite every row to include the new column value
        default_val : Value = nil
        if dsql = new_col.default_sql
          default_ast = SQL::Parser.new(SQL::Lexer.new(dsql).tokenize).parse_expr_public
          empty_row = Array(Value).new(new_cols.size, nil.as(Value))
          default_val = eval_expr(default_ast, empty_row, new_schema, binder)
        end

        bt.scan do |k, v|
          row = codec.decode(v)
          row << default_val
          bt.update(k, codec.encode(row))
        end

        @tables[stmt.tbl] = Table.new(new_schema, table.next_rowid)

      when AST::AlterDropColumn
        col_name = cmd.col
        col_idx = schema.cols.index { |c| c.name == col_name } ||
                  raise DB::Error.new("no such column: #{col_name}")
        if pk_idx = schema.pk_idx
          raise DB::Error.new("cannot drop PRIMARY KEY column #{col_name}") if pk_idx == col_idx
        end

        # Drop any indexes that cover this column
        covering = @indexes.select { |_, m| m.table == stmt.tbl && m.cols.includes?(col_name) }
        covering.each_key do |idx_name|
          @indexes.delete(idx_name)
          if old_ibt = @index_btrees.delete(idx_name)
            old_ibt.free_tree
          end
        end
        @col_indexes.reject! { |k, _| k == "#{stmt.tbl}.#{col_name}" }

        new_cols = schema.cols.each_with_index.reject { |_, i| i == col_idx }.map(&.first).to_a
        pk_names = schema.pk_idx ? [schema.cols[schema.pk_idx.not_nil!].name] : [] of String
        new_schema = TableSchema.new(stmt.tbl, new_cols, pk_names)

        bt = @btrees[stmt.tbl].not_nil!
        bt.scan do |k, v|
          row = codec.decode(v)
          row.delete_at(col_idx)
          bt.update(k, codec.encode(row))
        end

        @tables[stmt.tbl] = Table.new(new_schema, table.next_rowid)

      when AST::AlterRenameColumn
        old_name = cmd.old_col
        new_name = cmd.new_col
        col_idx = schema.cols.index { |c| c.name == old_name } ||
                  raise DB::Error.new("no such column: #{old_name}")
        raise DB::Error.new("column #{new_name} already exists") if schema.cols.any? { |c| c.name == new_name }

        new_cols = schema.cols.each_with_index.map { |c, i|
          i == col_idx ? ColSchema.new(new_name, c.type_str, c.not_null, c.default_sql) : c
        }.to_a
        pk_names = schema.pk_idx ? [new_cols[schema.pk_idx.not_nil!].name] : [] of String
        new_schema = TableSchema.new(stmt.tbl, new_cols, pk_names)
        @tables[stmt.tbl] = Table.new(new_schema, table.next_rowid)

        # Update index metadata and @col_indexes for this column
        old_col_key = "#{stmt.tbl}.#{old_name}"
        new_col_key = "#{stmt.tbl}.#{new_name}"
        if idx_names = @col_indexes.delete(old_col_key)
          @col_indexes[new_col_key] = idx_names
          idx_names.each do |idx_name|
            if meta = @indexes[idx_name]?
              updated_cols = meta.cols.map { |c| c == old_name ? new_name : c }
              @indexes[idx_name] = Storage::IndexMeta.new(meta.name, meta.table, updated_cols, meta.root_page, meta.unique)
            end
          end
        end

      when AST::AlterRenameTo
        new_tbl_name = cmd.new_name
        raise DB::Error.new("table #{new_tbl_name} already exists") if @tables.has_key?(new_tbl_name)

        old_tbl = @tables.delete(stmt.tbl).not_nil!
        new_schema = TableSchema.new(new_tbl_name, old_tbl.schema.cols,
                                     old_tbl.schema.pk_idx ? [old_tbl.schema.cols[old_tbl.schema.pk_idx.not_nil!].name] : [] of String)
        @tables[new_tbl_name] = Table.new(new_schema, old_tbl.next_rowid)

        if bt = @btrees.delete(stmt.tbl)
          @btrees[new_tbl_name] = bt
        end

        # Update index metadata
        @indexes.each do |idx_name, meta|
          if meta.table == stmt.tbl
            @indexes[idx_name] = Storage::IndexMeta.new(meta.name, new_tbl_name, meta.cols, meta.root_page, meta.unique)
            if ibt = @index_btrees.delete(idx_name)
              @index_btrees[idx_name] = ibt
            end
          end
        end

        # Rekey @col_indexes
        old_prefix = "#{stmt.tbl}."
        new_prefix = "#{new_tbl_name}."
        to_move = @col_indexes.select { |k, _| k.starts_with?(old_prefix) }
        to_move.each do |old_key, v|
          @col_indexes.delete(old_key)
          @col_indexes[new_prefix + old_key[old_prefix.size..]] = v
        end
      end

      save_catalog
      @pager.commit unless in_transaction?
      ExecResult.new(0_i64, 0_i64)
    end

    private def exec_vacuum : ExecResult
      codec = Storage::RowCodec
      @tables.each_key do |tbl|
        bt_old = @btrees[tbl]? || next
        rows = [] of {Int64, Row}
        bt_old.scan { |k, v| rows << {codec.decode_key(k), codec.decode(v)} }
        bt_old.free_tree
        new_root = Storage::BTree.create(@pager)
        bt_new = Storage::BTree.new(@pager, new_root)
        rows.each { |rowid, row| bt_new.insert(codec.encode_key(rowid), codec.encode(row)) }
        @btrees[tbl] = bt_new
      end
      @indexes.each_key do |idx_name|
        meta = @indexes[idx_name]
        tbl = meta.table
        tbl_schema = @tables[tbl]?.try(&.schema) || next
        col_is = meta.cols.map { |cn| tbl_schema.cols.index { |c| c.name == cn } }
        next if col_is.any?(&.nil?)
        col_is_nn = col_is.map(&.not_nil!)
        bt_main = @btrees[tbl]? || next
        bt_old = @index_btrees[idx_name]? || next
        bt_old.free_tree
        new_root = Storage::BTree.create(@pager)
        bt_new = Storage::BTree.new(@pager, new_root)
        bt_main.scan do |k, v|
          row = codec.decode(v)
          rowid = codec.decode_key(k)
          vals = col_is_nn.map { |i| row[i] }
          next if vals.any?(&.nil?)
          bt_new.insert(codec.encode_index_key(vals, rowid), Bytes.new(0))
        end
        @index_btrees[idx_name] = bt_new
      end
      save_catalog
      @pager.commit
      ExecResult.new(0_i64, 0_i64)
    end

    private def exec_insert(stmt : AST::Insert, binder : ParamBinder) : ExecuteResult
      table = @tables[stmt.tbl]? || raise DB::Error.new("no such table: #{stmt.tbl}")
      schema = table.schema
      rows_affected = 0_i64
      codec = Storage::RowCodec
      returning_rows = stmt.returning ? [] of Row : nil

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

        # Apply column DEFAULT expressions for nil columns
        schema.cols.each_with_index do |col, i|
          if row[i].nil? && (dsql = col.default_sql)
            default_ast = SQL::Parser.new(SQL::Lexer.new(dsql).tokenize).parse_expr_public
            row[i] = eval_expr(default_ast, row, schema, binder)
          end
        end

        schema.cols.each_with_index do |col, i|
          raise DB::Error.new("NOT NULL constraint failed: #{schema.name}.#{col.name}") if col.not_null && row[i].nil?
        end

        bt = @btrees[stmt.tbl]? || raise DB::Error.new("no btree for table: #{stmt.tbl}")

        # Capture excluded_row for ON CONFLICT DO UPDATE SET excluded.col references
        excluded_row = row.dup if stmt.on_conflict_cols.any?

        # ON CONFLICT DO UPDATE — upsert by scanning for matching conflict columns
        if stmt.on_conflict_cols.any?
          existing_rowid = nil
          bt.scan do |k, v|
            existing = codec.decode(v)
            match = stmt.on_conflict_cols.all? do |cn|
              ci = schema.col_index(cn)
              compare_values(existing[ci], row[ci]) == 0
            end
            if match
              existing_rowid = codec.decode_key(k)
              break
            end
          end
          if erid = existing_rowid
            ekey = codec.encode_key(erid)
            old_row = codec.decode(bt.search(ekey).not_nil!)
            # ON CONFLICT DO UPDATE ... WHERE: skip update when condition is false
            if cond = stmt.on_conflict_where
              next unless eval_expr(cond, old_row, schema, binder, excluded_row)
            end
            new_row = old_row.dup
            stmt.on_conflict_updates.each do |cn, upd_expr|
              new_row[schema.col_index(cn)] = eval_expr(upd_expr, old_row, schema, binder, excluded_row)
            end
            bt.update(ekey, codec.encode(new_row))
            update_index_entries(stmt.tbl, schema, old_row, new_row, erid)
            @last_insert_rowid = erid
            rows_affected += 1
            returning_rows.try(&.<< new_row)
            next
          end
        end

        key = codec.encode_key(rowid)
        val = codec.encode(row)
        case stmt.conflict
        when AST::Insert::Conflict::Replace
          if bt.search(key)
            bt.update(key, val)
          else
            bt.insert(key, val)
            table.next_rowid = rowid + 1 if rowid >= table.next_rowid
          end
        when AST::Insert::Conflict::Ignore
          unless bt.search(key)
            bt.insert(key, val)
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
          table.next_rowid = rowid + 1 if rowid >= table.next_rowid
        end

        insert_index_entries(stmt.tbl, schema, row, rowid)
        @last_insert_rowid = rowid
        rows_affected += 1
        returning_rows.try(&.<< row)
      end

      save_catalog if @btrees[stmt.tbl]?
      if (ret_cols = stmt.returning) && (rrows = returning_rows)
        col_names, out_rows = project_cols(ret_cols, rrows, schema, binder)
        return QueryResult.new(col_names, out_rows)
      end
      ExecResult.new(rows_affected, @last_insert_rowid)
    end

    private def exec_select(stmt : AST::Select, binder : ParamBinder, committed_only : Bool = false) : ExecuteResult
      from_tbl = stmt.from_tbl

      # ── Sub-select in FROM ──────────────────────────────────────────────────
      if from_subq = stmt.from_subquery
        raise DB::Error.new("JOINs on subquery in FROM not yet supported") if stmt.joins.any?
        alias_name = stmt.from_alias || "_sub_"
        inner = exec_select(from_subq, binder, committed_only)
        inner_qr = inner.as?(QueryResult) || raise DB::Error.new("subquery failed")
        sub_cols = inner_qr.col_names.map { |n| ColSchema.new("#{alias_name}.#{n}", "TEXT", false) }
        sub_schema = TableSchema.new("_sub_", sub_cols, [] of String)
        sub_rows = inner_qr.rows

        if where = stmt.where_expr
          sub_rows = sub_rows.select { |row| truthy?(eval_expr(where, row, sub_schema, binder)) }
        end
        return exec_group_by(stmt, sub_rows, sub_schema, binder) if stmt.group_by.any?
        if is_aggregate_select?(stmt)
          sc = stmt.sel_cols[0]
          agg = eval_with_group(sc.expr, sub_rows, sub_schema, binder)
          return QueryResult.new([sel_col_name(sc)], [[agg]])
        end
        col_names, result_rows = project_cols(stmt.sel_cols, sub_rows, sub_schema, binder)
        if stmt.distinct
          result_rows = dedup_rows(result_rows)
          result_rows = order_projected(stmt, col_names, result_rows, binder)
          result_rows = apply_limit(stmt, result_rows, binder)
        else
          unless stmt.order_by.empty?
            stmt.order_by.each do |col_ref, asc|
              col_idx = col_ref_index(col_ref, sub_schema)
              sub_rows = sub_rows.sort { |a, b|
                cmp = compare_values(a[col_idx], b[col_idx])
                asc ? cmp : -cmp
              }
            end
          end
          if limit_expr = stmt.limit_expr
            lim = to_i64(eval_expr(limit_expr, [] of Value, nil, binder))
            off = stmt.offset_expr ? to_i64(eval_expr(stmt.offset_expr.not_nil!, [] of Value, nil, binder)).to_i : 0
            sub_rows = sub_rows[off, lim.to_i] || [] of Row
          end
          col_names, result_rows = project_cols(stmt.sel_cols, sub_rows, sub_schema, binder)
        end
        return QueryResult.new(col_names, result_rows)
      end
      # ── end sub-select ──────────────────────────────────────────────────────

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

      # Concurrent readers use the committed-tables snapshot for schema isolation
      # (so they don't see tables created/dropped inside an uncommitted transaction).
      table_map = committed_only ? (@committed_tables || @tables) : @tables
      table = table_map[from_tbl]? || raise DB::Error.new("no such table: #{from_tbl}")
      schema = table.schema

      if bt_base = @btrees[from_tbl]?
        codec = Storage::RowCodec
        # Concurrent readers get a committed-only view of the btree.
        bt = committed_only ? Storage::BTree.new(@pager, bt_base.root_page, committed_only: true) : bt_base

        # ── JOIN path ──────────────────────────────────────────────────────────
        if stmt.joins.any?
          left_alias = stmt.from_alias || from_tbl

          # Collect all (alias, schema, btree) triples
          join_parts = Array(Tuple(String, TableSchema, Storage::BTree)).new
          join_parts << {left_alias, schema, bt}
          stmt.joins.each do |join|
            j_tbl = join.tbl
            j_alias = join.alias_name || j_tbl
            j_table = @tables[j_tbl]? || raise DB::Error.new("no such table: #{j_tbl}")
            j_bt_base = @btrees[j_tbl]? || raise DB::Error.new("no btree for table: #{j_tbl}")
            j_bt = committed_only ? Storage::BTree.new(@pager, j_bt_base.root_page, committed_only: true) : j_bt_base
            join_parts << {j_alias, j_table.schema, j_bt}
          end

          # Full joined schema (all tables combined)
          joined_schema = build_joined_schema(join_parts.map { |a, s, _| {a, s} })

          # Materialise left rows
          current_rows = Array(Row).new
          join_parts[0][2].scan { |_, v| current_rows << codec.decode(v) }

          # Expand through each JOIN
          stmt.joins.each_with_index do |join, i|
            j_alias2, j_schema2, j_bt2 = join_parts[i + 1]
            j_cols = j_schema2.cols.size
            partial_schema = build_joined_schema(join_parts[0..i + 1].map { |a, s, _| {a, s} })

            next_rows = Array(Row).new
            current_rows.each do |cur_row|
              matched = false
              j_bt2.scan do |_, v2|
                j_row = codec.decode(v2)
                combined = cur_row + j_row
                on_ok = if on_expr = join.on_expr
                  truthy?(eval_expr(on_expr, combined, partial_schema, binder))
                else
                  true
                end
                next unless on_ok
                matched = true
                next_rows << combined
              end
              if !matched && join.join_type == AST::JoinClause::Type::Left
                next_rows << cur_row + Array(Value).new(j_cols, nil.as(Value))
              end
            end
            current_rows = next_rows
          end

          # Apply WHERE
          joined_rows = if where_expr = stmt.where_expr
            current_rows.select { |row| truthy?(eval_expr(where_expr, row, joined_schema, binder)) }
          else
            current_rows
          end

          # GROUP BY on joined rows
          return exec_group_by(stmt, joined_rows, joined_schema, binder) if stmt.group_by.any?

          # Aggregates on joined rows
          if is_aggregate_select?(stmt)
            sc = stmt.sel_cols[0]
            agg = eval_with_group(sc.expr, joined_rows, joined_schema, binder)
            return QueryResult.new([sel_col_name(sc)], [[agg]])
          end

          col_names, result_rows = project_cols(stmt.sel_cols, joined_rows, joined_schema, binder)
          if stmt.distinct
            result_rows = dedup_rows(result_rows)
            result_rows = order_projected(stmt, col_names, result_rows, binder)
            result_rows = apply_limit(stmt, result_rows, binder)
          else
            # ORDER BY
            unless stmt.order_by.empty?
              stmt.order_by.each do |col_ref, asc|
                col_idx = col_ref_index(col_ref, joined_schema)
                joined_rows = joined_rows.sort { |a, b|
                  cmp = compare_values(a[col_idx], b[col_idx])
                  asc ? cmp : -cmp
                }
              end
            end

            # LIMIT / OFFSET
            if limit_expr = stmt.limit_expr
              lim = to_i64(eval_expr(limit_expr, [] of Value, nil, binder))
              off = if off_expr = stmt.offset_expr
                to_i64(eval_expr(off_expr, [] of Value, nil, binder)).to_i
              else
                0
              end
              joined_rows = joined_rows[off, lim.to_i] || [] of Row
            end

            col_names, result_rows = project_cols(stmt.sel_cols, joined_rows, joined_schema, binder)
          end
          return QueryResult.new(col_names, result_rows)
        end
        # ── end JOIN path ──────────────────────────────────────────────────────

        if is_aggregate_select?(stmt)
          sc = stmt.sel_cols[0]
          col_name = sel_col_name(sc)
          agg_val = if sc.expr.is_a?(AST::FnCall) && {"COUNT", "MAX", "MIN", "SUM", "AVG"}.includes?(sc.expr.as(AST::FnCall).fn)
            compute_aggregate_scan(bt, sc.expr.as(AST::FnCall), schema, binder, stmt.where_expr)
          else
            all_rows = [] of Row
            bt.scan do |_, v|
              r = codec.decode(v)
              next if (w = stmt.where_expr) && !truthy?(eval_expr(w, r, schema, binder))
              all_rows << r
            end
            eval_with_group(sc.expr, all_rows, schema, binder)
          end
          return QueryResult.new([col_name], [[agg_val]])
        end

        rows = [] of Row
        if pk_key = extract_pk_key(schema, stmt.where_expr, binder)
          if raw = bt.search(pk_key)
            row = codec.decode(raw)
            if where = stmt.where_expr
              rows << row if truthy?(eval_expr(where, row, schema, binder))
            else
              rows << row
            end
          end
        elsif !committed_only && (idx_pair = extract_index_lookup(from_tbl, schema, stmt.where_expr, binder))
          idx_bt, prefix = idx_pair
          idx_bt.scan_from(prefix) do |k, _|
            break unless k.size >= prefix.size && k[0, prefix.size] == prefix
            rowid = Storage::RowCodec.decode_index_rowid(k)
            next unless raw = bt.search(Storage::RowCodec.encode_key(rowid))
            row = codec.decode(raw)
            if where = stmt.where_expr
              rows << row if truthy?(eval_expr(where, row, schema, binder))
            else
              rows << row
            end
          end
        elsif !committed_only && (between = extract_index_between(from_tbl, schema, stmt.where_expr, binder))
          idx_bt, lo_prefix, hi_prefix, lo_op, hi_op = between
          idx_bt.scan_from(lo_prefix) do |k, _|
            col_part = k[0, k.size - 8]
            next if lo_op == AST::BinOp::Op::Gt && col_part == lo_prefix
            cmp = (col_part <=> hi_prefix)
            break if cmp > 0 || (cmp == 0 && hi_op == AST::BinOp::Op::Lt)
            rowid = Storage::RowCodec.decode_index_rowid(k)
            next unless raw = bt.search(Storage::RowCodec.encode_key(rowid))
            row = codec.decode(raw)
            if where = stmt.where_expr
              rows << row if truthy?(eval_expr(where, row, schema, binder))
            else
              rows << row
            end
          end
        elsif !committed_only && (range = extract_index_range(from_tbl, schema, stmt.where_expr, binder))
          idx_bt, prefix, range_op = range
          case range_op
          when AST::BinOp::Op::Ge
            idx_bt.scan_from(prefix) do |k, _|
              rowid = Storage::RowCodec.decode_index_rowid(k)
              next unless raw = bt.search(Storage::RowCodec.encode_key(rowid))
              row = codec.decode(raw)
              if where = stmt.where_expr
                rows << row if truthy?(eval_expr(where, row, schema, binder))
              else
                rows << row
              end
            end
          when AST::BinOp::Op::Gt
            idx_bt.scan_from(prefix) do |k, _|
              col_part = k[0, k.size - 8]
              next if col_part == prefix
              rowid = Storage::RowCodec.decode_index_rowid(k)
              next unless raw = bt.search(Storage::RowCodec.encode_key(rowid))
              row = codec.decode(raw)
              if where = stmt.where_expr
                rows << row if truthy?(eval_expr(where, row, schema, binder))
              else
                rows << row
              end
            end
          when AST::BinOp::Op::Le
            idx_bt.scan do |k, _|
              col_part = k[0, k.size - 8]
              break if (col_part <=> prefix) > 0
              rowid = Storage::RowCodec.decode_index_rowid(k)
              next unless raw = bt.search(Storage::RowCodec.encode_key(rowid))
              row = codec.decode(raw)
              if where = stmt.where_expr
                rows << row if truthy?(eval_expr(where, row, schema, binder))
              else
                rows << row
              end
            end
          when AST::BinOp::Op::Lt
            idx_bt.scan do |k, _|
              col_part = k[0, k.size - 8]
              break if (col_part <=> prefix) >= 0
              rowid = Storage::RowCodec.decode_index_rowid(k)
              next unless raw = bt.search(Storage::RowCodec.encode_key(rowid))
              row = codec.decode(raw)
              if where = stmt.where_expr
                rows << row if truthy?(eval_expr(where, row, schema, binder))
              else
                rows << row
              end
            end
          end
        else
          bt.scan do |k, v|
            row = codec.decode(v)
            if where = stmt.where_expr
              next unless truthy?(eval_expr(where, row, schema, binder))
            end
            rows << row
          end
        end

        return exec_group_by(stmt, rows, schema, binder) if stmt.group_by.any?

        has_windows = stmt.sel_cols.any? { |sc| sc.expr.is_a?(AST::WindowExpr) }
        col_names, result_rows = project_cols(stmt.sel_cols, rows, schema, binder)
        if stmt.distinct
          result_rows = dedup_rows(result_rows)
          result_rows = order_projected(stmt, col_names, result_rows, binder)
          result_rows = apply_limit(stmt, result_rows, binder)
        elsif has_windows
          # Window functions are already computed; sort and limit projected rows
          result_rows = order_projected(stmt, col_names, result_rows, binder) unless stmt.order_by.empty?
          result_rows = apply_limit(stmt, result_rows, binder)
        else
          unless stmt.order_by.empty?
            stmt.order_by.each do |col_ref, asc|
              col_idx = col_ref_index(col_ref, schema)
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
        end
        return QueryResult.new(col_names, result_rows)
      end

      raise DB::Error.new("no btree for table: #{from_tbl}")
    end

    private def exec_update(stmt : AST::Update, binder : ParamBinder) : ExecuteResult
      table = @tables[stmt.tbl]? || raise DB::Error.new("no such table: #{stmt.tbl}")
      schema = table.schema
      rows_affected = 0_i64

      bt = @btrees[stmt.tbl]? || raise DB::Error.new("no btree for table: #{stmt.tbl}")
      codec = Storage::RowCodec
      to_update = [] of Tuple(Int64, Row, Row)

      if stmt.from_joins.any?
        # UPDATE ... FROM: join target table with FROM tables, filter, collect updates
        tbl_alias = stmt.tbl
        join_parts = [{tbl_alias, schema, bt}] of Tuple(String, TableSchema, Storage::BTree)
        stmt.from_joins.each do |join|
          j_tbl = join.tbl
          j_alias = join.alias_name || j_tbl
          j_table = @tables[j_tbl]? || raise DB::Error.new("no such table: #{j_tbl}")
          j_bt = @btrees[j_tbl]? || raise DB::Error.new("no btree for table: #{j_tbl}")
          join_parts << {j_alias, j_table.schema, j_bt}
        end
        joined_schema = build_joined_schema(join_parts.map { |a, s, _| {a, s} })

        # Collect (rowid, target_row) from target table
        target_pairs = [] of Tuple(Int64, Row)
        bt.scan { |k, v| target_pairs << {codec.decode_key(k), codec.decode(v)} }

        target_pairs.each do |rowid, target_row|
          current = [target_row] of Row
          stmt.from_joins.each_with_index do |join, i|
            _, _, j_bt2 = join_parts[i + 1]
            _, j_schema2, _ = join_parts[i + 1]
            partial_schema = build_joined_schema(join_parts[0..i + 1].map { |a, s, _| {a, s} })
            next_rows = [] of Row
            current.each do |cur_row|
              j_bt2.scan do |_, v2|
                j_row = codec.decode(v2)
                combined = cur_row + j_row
                on_ok = if on_expr = join.on_expr
                  truthy?(eval_expr(on_expr, combined, partial_schema, binder))
                else
                  true
                end
                next_rows << combined if on_ok
              end
            end
            current = next_rows
          end

          current.each do |joined_row|
            if where = stmt.where_expr
              next unless truthy?(eval_expr(where, joined_row, joined_schema, binder))
            end
            new_row = target_row.dup
            stmt.assignments.each do |col_name, val_expr|
              col_idx = schema.col_index(col_name)
              new_row[col_idx] = eval_expr(val_expr, joined_row, joined_schema, binder)
            end
            to_update << {rowid, target_row, new_row}
            break  # one update per target row (first match)
          end
        end
      elsif pk_key = extract_pk_key(schema, stmt.where_expr, binder)
        if raw = bt.search(pk_key)
          row = codec.decode(raw)
          if where = stmt.where_expr
            if truthy?(eval_expr(where, row, schema, binder))
              new_row = row.dup
              stmt.assignments.each do |col_name, val_expr|
                col_idx = schema.col_index(col_name)
                new_row[col_idx] = eval_expr(val_expr, row, schema, binder)
              end
              to_update << {codec.decode_key(pk_key), row, new_row}
            end
          else
            new_row = row.dup
            stmt.assignments.each do |col_name, val_expr|
              col_idx = schema.col_index(col_name)
              new_row[col_idx] = eval_expr(val_expr, row, schema, binder)
            end
            to_update << {codec.decode_key(pk_key), row, new_row}
          end
        end
      else
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
          to_update << {rowid, row, new_row}
        end
      end

      returning_rows = stmt.returning ? [] of Row : nil
      to_update.each do |rowid, old_row, new_row|
        schema.cols.each_with_index do |col, i|
          raise DB::Error.new("NOT NULL constraint failed: #{schema.name}.#{col.name}") if col.not_null && new_row[i].nil?
        end
        key = codec.encode_key(rowid)
        bt.update(key, codec.encode(new_row))
        update_index_entries(stmt.tbl, schema, old_row, new_row, rowid)
        rows_affected += 1
        returning_rows.try(&.<< new_row)
      end

      save_catalog if @btrees[stmt.tbl]?
      if (ret_cols = stmt.returning) && (rrows = returning_rows)
        col_names, out_rows = project_cols(ret_cols, rrows, schema, binder)
        return QueryResult.new(col_names, out_rows)
      end
      ExecResult.new(rows_affected, @last_insert_rowid)
    end

    private def exec_delete(stmt : AST::Delete, binder : ParamBinder) : ExecuteResult
      table = @tables[stmt.tbl]? || raise DB::Error.new("no such table: #{stmt.tbl}")
      schema = table.schema
      rows_affected = 0_i64

      bt = @btrees[stmt.tbl]? || raise DB::Error.new("no btree for table: #{stmt.tbl}")
      codec = Storage::RowCodec
      to_delete = [] of Tuple(Bytes, Row)

      if stmt.using_joins.any?
        # DELETE ... USING: join target with USING tables, collect matching target keys
        tbl_alias = stmt.tbl
        join_parts = [{tbl_alias, schema, bt}] of Tuple(String, TableSchema, Storage::BTree)
        stmt.using_joins.each do |join|
          j_tbl = join.tbl
          j_alias = join.alias_name || j_tbl
          j_table = @tables[j_tbl]? || raise DB::Error.new("no such table: #{j_tbl}")
          j_bt = @btrees[j_tbl]? || raise DB::Error.new("no btree for table: #{j_tbl}")
          join_parts << {j_alias, j_table.schema, j_bt}
        end
        joined_schema = build_joined_schema(join_parts.map { |a, s, _| {a, s} })

        seen_keys = Set(Int64).new
        bt.scan do |k, v|
          rowid = codec.decode_key(k)
          next if seen_keys.includes?(rowid)
          target_row = codec.decode(v)
          current = [target_row] of Row

          stmt.using_joins.each_with_index do |join, i|
            _, _, j_bt2 = join_parts[i + 1]
            partial_schema = build_joined_schema(join_parts[0..i + 1].map { |a, s, _| {a, s} })
            next_rows = [] of Row
            current.each do |cur_row|
              j_bt2.scan do |_, v2|
                j_row = codec.decode(v2)
                combined = cur_row + j_row
                on_ok = if on_expr = join.on_expr
                  truthy?(eval_expr(on_expr, combined, partial_schema, binder))
                else
                  true
                end
                next_rows << combined if on_ok
              end
            end
            current = next_rows
          end

          current.each do |joined_row|
            if where = stmt.where_expr
              next unless truthy?(eval_expr(where, joined_row, joined_schema, binder))
            end
            seen_keys.add(rowid)
            to_delete << {k.dup, target_row}
            break
          end
        end
      elsif pk_key = extract_pk_key(schema, stmt.where_expr, binder)
        if raw = bt.search(pk_key)
          row = codec.decode(raw)
          if where = stmt.where_expr
            to_delete << {pk_key.dup, row} if truthy?(eval_expr(where, row, schema, binder))
          else
            to_delete << {pk_key.dup, row}
          end
        end
      else
        bt.scan do |k, v|
          row = codec.decode(v)
          if where = stmt.where_expr
            next unless truthy?(eval_expr(where, row, schema, binder))
          end
          to_delete << {k.dup, row}
        end
      end

      returning_rows = stmt.returning ? [] of Row : nil
      to_delete.each do |k, row|
        rowid = codec.decode_key(k)
        bt.delete(k)
        delete_index_entries(stmt.tbl, schema, row, rowid)
        rows_affected += 1
        returning_rows.try(&.<< row)
      end

      save_catalog if @btrees[stmt.tbl]?
      if (ret_cols = stmt.returning) && (rrows = returning_rows)
        col_names, out_rows = project_cols(ret_cols, rrows, schema, binder)
        return QueryResult.new(col_names, out_rows)
      end
      ExecResult.new(rows_affected, @last_insert_rowid)
    end

    private def exec_drop_table(stmt : AST::DropTable, binder : ParamBinder) : ExecResult
      if stmt.if_exists
        return ExecResult.new(0_i64, 0_i64) unless @tables.has_key?(stmt.tbl)
        @tables.delete(stmt.tbl)
      else
        @tables.delete(stmt.tbl) || raise DB::Error.new("no such table: #{stmt.tbl}")
      end
      if old_bt = @btrees.delete(stmt.tbl)
        old_bt.free_tree
      end
      @indexes.select { |_, m| m.table == stmt.tbl }.each_key do |idx_name|
        @indexes.delete(idx_name)
        if old_ibt = @index_btrees.delete(idx_name)
          old_ibt.free_tree
        end
      end
      @col_indexes.reject! { |k, _| k.starts_with?("#{stmt.tbl}.") }
      save_catalog
      @pager.commit unless in_transaction?
      ExecResult.new(0_i64, 0_i64)
    end

    # Build a flat TableSchema for JOIN evaluation. Columns are named "alias.col".
    private def build_joined_schema(tables : Array(Tuple(String, TableSchema))) : TableSchema
      combined_cols = tables.flat_map { |tbl_alias, schema|
        schema.cols.map { |c| ColSchema.new("#{tbl_alias}.#{c.name}", c.type_str, c.not_null) }
      }
      TableSchema.new("_join_", combined_cols, [] of String)
    end

    # Returns the btree key for a simple "int_pk_col = value" WHERE predicate.
    private def extract_pk_key(schema : TableSchema, where_expr : AST::Expr?, binder : ParamBinder) : Bytes?
      pk_idx = schema.pk_idx
      return nil if pk_idx.nil? || where_expr.nil?
      op = where_expr.as?(AST::BinOp)
      return nil unless op && op.op == AST::BinOp::Op::Eq
      col_ref, val_expr = if (l = op.left.as?(AST::ColRef))
        {l, op.right}
      elsif (r = op.right.as?(AST::ColRef))
        {r, op.left}
      else
        return nil
      end
      pk_col = schema.cols[pk_idx]
      return nil unless col_ref.col == pk_col.name && pk_col.type_str.includes?("INT")
      val = eval_expr(val_expr, [] of Value, schema, binder)
      return nil unless val.is_a?(Int64)
      Storage::RowCodec.encode_key(val)
    end

    # Returns {index_btree, prefix} if WHERE col = val matches a secondary index.
    private def extract_index_lookup(tbl : String, schema : TableSchema, where_expr : AST::Expr?, binder : ParamBinder) : Tuple(Storage::BTree, Bytes)?
      return nil if where_expr.nil?
      op = where_expr.as?(AST::BinOp)
      return nil unless op && op.op == AST::BinOp::Op::Eq
      col_ref, val_expr = if (l = op.left.as?(AST::ColRef))
        {l, op.right}
      elsif (r = op.right.as?(AST::ColRef))
        {r, op.left}
      else
        return nil
      end
      col_key = "#{tbl}.#{col_ref.col}"
      idx_names = @col_indexes[col_key]?
      return nil unless idx_names && !idx_names.empty?
      idx_bt = @index_btrees[idx_names.first]? || return nil
      val = eval_expr(val_expr, [] of Value, schema, binder)
      return nil if val.nil?
      return nil unless val.is_a?(Int64) || val.is_a?(String)
      prefix = Storage::RowCodec.encode_index_prefix(val.as(SQL::Value))
      {idx_bt, prefix}
    end

    # Returns {index_btree, col_prefix, op} for a simple range predicate on an indexed column.
    private def extract_index_range(tbl : String, schema : TableSchema, where_expr : AST::Expr?, binder : ParamBinder) : Tuple(Storage::BTree, Bytes, AST::BinOp::Op)?
      return nil if where_expr.nil?
      op = where_expr.as?(AST::BinOp) || return nil
      raw_op = op.op
      case raw_op
      when AST::BinOp::Op::Gt, AST::BinOp::Op::Ge, AST::BinOp::Op::Lt, AST::BinOp::Op::Le
      else
        return nil
      end

      col_ref, val_expr, effective_op = if (l = op.left.as?(AST::ColRef))
        {l, op.right, raw_op}
      elsif (r = op.right.as?(AST::ColRef))
        flipped = case raw_op
        when AST::BinOp::Op::Gt then AST::BinOp::Op::Lt
        when AST::BinOp::Op::Ge then AST::BinOp::Op::Le
        when AST::BinOp::Op::Lt then AST::BinOp::Op::Gt
        when AST::BinOp::Op::Le then AST::BinOp::Op::Ge
        else raw_op
        end
        {r, op.left, flipped}
      else
        return nil
      end

      col_key = "#{tbl}.#{col_ref.col}"
      idx_names = @col_indexes[col_key]?
      return nil unless idx_names && !idx_names.empty?
      idx_bt = @index_btrees[idx_names.first]? || return nil

      val = eval_expr(val_expr, [] of Value, schema, binder)
      return nil if val.nil?
      return nil unless val.is_a?(Int64) || val.is_a?(String)

      prefix = Storage::RowCodec.encode_index_prefix(val.as(SQL::Value))
      {idx_bt, prefix, effective_op}
    end

    # Returns {idx_bt, lo_prefix, hi_prefix, lo_op, hi_op} when WHERE is
    # AND(Ge/Gt(col, lo), Le/Lt(col, hi)) — i.e., the BETWEEN pattern.
    private def extract_index_between(tbl : String, schema : TableSchema, where_expr : AST::Expr?, binder : ParamBinder) : Tuple(Storage::BTree, Bytes, Bytes, AST::BinOp::Op, AST::BinOp::Op)?
      return nil if where_expr.nil?
      and_op = where_expr.as?(AST::BinOp) || return nil
      return nil unless and_op.op == AST::BinOp::Op::And

      lo_b = and_op.left.as?(AST::BinOp)  || return nil
      hi_b = and_op.right.as?(AST::BinOp) || return nil
      return nil unless lo_b.op == AST::BinOp::Op::Ge || lo_b.op == AST::BinOp::Op::Gt
      return nil unless hi_b.op == AST::BinOp::Op::Le || hi_b.op == AST::BinOp::Op::Lt

      lo_col = lo_b.left.as?(AST::ColRef) || return nil
      hi_col = hi_b.left.as?(AST::ColRef) || return nil
      return nil unless lo_col.col == hi_col.col

      col_key = "#{tbl}.#{lo_col.col}"
      idx_names = @col_indexes[col_key]? || return nil
      idx_bt = @index_btrees[idx_names.first]? || return nil

      lo_val = eval_expr(lo_b.right, [] of Value, schema, binder)
      hi_val = eval_expr(hi_b.right, [] of Value, schema, binder)
      return nil unless (lo_val.is_a?(Int64) || lo_val.is_a?(String)) && (hi_val.is_a?(Int64) || hi_val.is_a?(String))

      lo_prefix = Storage::RowCodec.encode_index_prefix(lo_val.as(SQL::Value))
      hi_prefix = Storage::RowCodec.encode_index_prefix(hi_val.as(SQL::Value))
      {idx_bt, lo_prefix, hi_prefix, lo_b.op, hi_b.op}
    end

    # Insert index entries for a newly inserted row.
    private def insert_index_entries(tbl : String, schema : TableSchema, row : Row, rowid : Int64) : Nil
      schema.cols.each do |col|
        col_key = "#{tbl}.#{col.name}"
        idx_names = @col_indexes[col_key]? || next
        idx_names.each do |idx_name|
          meta = @indexes[idx_name]? || next
          bt   = @index_btrees[idx_name]? || next
          vals = meta.cols.map { |cn| row[schema.col_index(cn)] }
          next if vals.any?(&.nil?)
          if meta.unique
            prefix = Storage::RowCodec.encode_index_prefix(vals)
            dup = false
            bt.scan_from(prefix) do |ik, _|
              dup = ik.size >= prefix.size && ik[0, prefix.size] == prefix
              break
            end
            raise DB::Error.new("UNIQUE constraint failed: #{tbl}.#{meta.cols.join(",")}") if dup
          end
          bt.insert(Storage::RowCodec.encode_index_key(vals, rowid), Bytes.new(0))
        end
      end
    end

    # Delete index entries for a removed row.
    private def delete_index_entries(tbl : String, schema : TableSchema, row : Row, rowid : Int64) : Nil
      schema.cols.each do |col|
        col_key = "#{tbl}.#{col.name}"
        idx_names = @col_indexes[col_key]? || next
        idx_names.each do |idx_name|
          meta = @indexes[idx_name]? || next
          bt   = @index_btrees[idx_name]? || next
          vals = meta.cols.map { |cn| row[schema.col_index(cn)] }
          next if vals.any?(&.nil?)
          bt.delete(Storage::RowCodec.encode_index_key(vals, rowid))
        end
      end
    end

    # Update index entries when a row's indexed columns change.
    private def update_index_entries(tbl : String, schema : TableSchema, old_row : Row, new_row : Row, rowid : Int64) : Nil
      schema.cols.each do |col|
        col_key = "#{tbl}.#{col.name}"
        idx_names = @col_indexes[col_key]? || next
        idx_names.each do |idx_name|
          meta = @indexes[idx_name]? || next
          bt   = @index_btrees[idx_name]? || next
          old_vals = meta.cols.map { |cn| old_row[schema.col_index(cn)] }
          new_vals = meta.cols.map { |cn| new_row[schema.col_index(cn)] }
          next if old_vals == new_vals
          bt.delete(Storage::RowCodec.encode_index_key(old_vals, rowid)) unless old_vals.any?(&.nil?)
          unless new_vals.any?(&.nil?)
            if meta.unique
              prefix = Storage::RowCodec.encode_index_prefix(new_vals)
              dup = false
              bt.scan_from(prefix) do |ik, _|
                dup = ik.size >= prefix.size && ik[0, prefix.size] == prefix
                break
              end
              raise DB::Error.new("UNIQUE constraint failed: #{tbl}.#{meta.cols.join(",")}") if dup
            end
            bt.insert(Storage::RowCodec.encode_index_key(new_vals, rowid), Bytes.new(0))
          end
        end
      end
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
        if (arg = fn.args[0]?) && !arg.is_a?(AST::Star)
          rows.count { |r| !eval_expr(arg, r, schema, binder).nil? }.to_i64.as(Value)
        else
          rows.size.to_i64.as(Value)
        end
      when "MAX"
        if arg = fn.args[0]?
          vals = rows.compact_map { |r| eval_expr(arg, r, schema, binder) }
          vals.max_by? { |v| compare_values(v, vals[0]) }
        else
          nil
        end
      when "MIN"
        if arg = fn.args[0]?
          vals = rows.compact_map { |r| eval_expr(arg, r, schema, binder) }
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
      when "AVG"
        if arg = fn.args[0]?
          num_vals = rows.compact_map { |r|
            v = eval_expr(arg, r, schema, binder)
            case v
            when Int64   then v.to_f64
            when Float64 then v
            else              nil
            end
          }
          num_vals.empty? ? nil : (num_vals.sum / num_vals.size.to_f64).as(Value)
        else
          nil
        end
      else
        nil
      end
    end

    private def is_aggregate_select?(stmt : AST::Select) : Bool
      return false if stmt.group_by.any?
      return false unless stmt.sel_cols.size == 1
      contains_aggregate?(stmt.sel_cols[0].expr)
    end

    private def contains_aggregate?(expr : AST::Expr) : Bool
      case expr
      when AST::FnCall
        {"COUNT", "MAX", "MIN", "SUM", "AVG"}.includes?(expr.fn) ||
          expr.args.any? { |a| contains_aggregate?(a) }
      when AST::BinOp
        contains_aggregate?(expr.left) || contains_aggregate?(expr.right)
      when AST::IsNull
        contains_aggregate?(expr.expr)
      else
        false
      end
    end

    private def exec_group_by(stmt : AST::Select, rows : Array(Row), schema : TableSchema, binder : ParamBinder) : QueryResult
      groups = Hash(String, Array(Row)).new
      rows.each do |row|
        key = stmt.group_by.map { |e| eval_expr(e, row, schema, binder).inspect }.join("\x00")
        (groups[key] ||= [] of Row) << row
      end

      col_names = stmt.sel_cols.map { |sc| sel_col_name(sc) }
      result_rows = [] of Row

      groups.each do |_, group_rows|
        if having = stmt.having_expr
          next unless truthy?(eval_with_group(having, group_rows, schema, binder))
        end
        result_row = stmt.sel_cols.flat_map { |sc|
          if sc.expr.is_a?(AST::Star)
            group_rows[0].dup
          else
            [eval_with_group(sc.expr, group_rows, schema, binder)]
          end
        }
        result_rows << result_row
      end

      if stmt.sel_cols.size == 1 && stmt.sel_cols[0].expr.is_a?(AST::Star)
        col_names = schema.cols.map { |c|
          dot = c.name.index('.'); dot ? c.name[(dot + 1)..] : c.name
        }
      end

      unless stmt.order_by.empty?
        stmt.order_by.each do |col_ref, asc|
          order_idx = col_names.index(col_ref.col) ||
                      col_names.index { |n| n.ends_with?(".#{col_ref.col}") } ||
                      col_ref_index(col_ref, schema)
          result_rows = result_rows.sort { |a, b|
            cmp = compare_values(a[order_idx], b[order_idx])
            asc ? cmp : -cmp
          }
        end
      end

      result_rows = dedup_rows(result_rows) if stmt.distinct

      if limit_expr = stmt.limit_expr
        lim = to_i64(eval_expr(limit_expr, [] of Value, nil, binder))
        off = stmt.offset_expr ? to_i64(eval_expr(stmt.offset_expr.not_nil!, [] of Value, nil, binder)).to_i : 0
        result_rows = result_rows[off, lim.to_i] || [] of Row
      end

      QueryResult.new(col_names, result_rows)
    end

    private def eval_with_group(expr : AST::Expr, group_rows : Array(Row), schema : TableSchema, binder : ParamBinder) : Value
      case expr
      when AST::FnCall
        if {"COUNT", "MAX", "MIN", "SUM", "AVG"}.includes?(expr.fn)
          compute_aggregate(expr, group_rows, schema, binder)
        elsif expr.fn == "COALESCE" || expr.fn == "IFNULL"
          expr.args.each do |arg|
            v = eval_with_group(arg, group_rows, schema, binder)
            return v unless v.nil?
          end
          nil.as(Value)
        elsif expr.fn == "NULLIF" && expr.args.size >= 2
          a = eval_with_group(expr.args[0], group_rows, schema, binder)
          b = eval_with_group(expr.args[1], group_rows, schema, binder)
          compare_values(a, b) == 0 ? nil.as(Value) : a
        else
          eval_expr(expr, group_rows[0], schema, binder)
        end
      when AST::BinOp
        l = eval_with_group(expr.left, group_rows, schema, binder)
        case expr.op
        when AST::BinOp::Op::And
          return false.as(Value) unless truthy?(l)
          eval_with_group(expr.right, group_rows, schema, binder)
        when AST::BinOp::Op::Or
          return l if truthy?(l)
          eval_with_group(expr.right, group_rows, schema, binder)
        when AST::BinOp::Op::Concat
          r = eval_with_group(expr.right, group_rows, schema, binder)
          return nil.as(Value) if l.nil? || r.nil?
          (l.to_s + r.to_s).as(Value)
        else
          r = eval_with_group(expr.right, group_rows, schema, binder)
          cmp_result(expr.op, l, r)
        end
      when AST::IsNull
        val = eval_with_group(expr.expr, group_rows, schema, binder)
        (expr.negated ? !val.nil? : val.nil?).as(Value)
      else
        row = group_rows.first? || [] of Value
        eval_expr(expr, row, schema, binder)
      end
    end

    private def order_projected(stmt : AST::Select, col_names : Array(String), rows : Array(Row), binder : ParamBinder) : Array(Row)
      return rows if stmt.order_by.empty?
      stmt.order_by.reduce(rows) do |r, (col_ref, asc)|
        col_idx = col_names.index(col_ref.col) ||
                  col_names.index { |n| n.ends_with?(".#{col_ref.col}") } || 0
        r.sort { |a, b| asc ? compare_values(a[col_idx], b[col_idx]) : compare_values(b[col_idx], a[col_idx]) }
      end
    end

    private def apply_limit(stmt : AST::Select, rows : Array(Row), binder : ParamBinder) : Array(Row)
      if limit_expr = stmt.limit_expr
        lim = to_i64(eval_expr(limit_expr, [] of Value, nil, binder))
        off = stmt.offset_expr ? to_i64(eval_expr(stmt.offset_expr.not_nil!, [] of Value, nil, binder)).to_i : 0
        rows[off, lim.to_i] || [] of Row
      else
        rows
      end
    end

    private def dedup_rows(rows : Array(Row)) : Array(Row)
      seen = Set(String).new
      rows.select do |row|
        fp = row.map { |v|
          case v
          when Nil     then "\x00"
          when Bool    then v ? "\x01T" : "\x01F"
          when Int64   then "\x02#{v}"
          when Float64 then "\x03#{v}"
          when String  then "\x04#{v.bytesize}:#{v}"
          when Bytes   then "\x05#{v.hexstring}"
          else "\x06#{v.inspect}"
          end
        }.join("\xFF")
        seen.add?(fp)  # returns nil (falsy) if already present
      end
    end

    # ── Window function evaluation ────────────────────────────────────────────

    private def resolve_window_functions(
      sel_cols : Array(AST::SelCol),
      rows : Array(Row),
      schema : TableSchema,
      binder : ParamBinder
    ) : Tuple(Array(AST::SelCol), Array(Row), TableSchema)
      new_sel_cols = sel_cols.dup
      new_cols = schema.cols.dup
      aug_rows = rows.map(&.dup)
      win_idx = schema.cols.size

      sel_cols.each_with_index do |sc, i|
        w = sc.expr.as?(AST::WindowExpr) || next
        values = compute_window_values(w, rows, schema, binder)
        syn = "_win_#{win_idx}"
        new_cols << ColSchema.new(syn, "ANY", false)
        aug_rows.each_with_index { |row, j| row << values[j] }
        alias_name = sc.alias_name || w.fn.downcase
        new_sel_cols[i] = AST::SelCol.new(AST::ColRef.new(nil, syn), alias_name)
        win_idx += 1
      end

      pk_names = schema.pk_idx ? [schema.cols[schema.pk_idx.not_nil!].name] : [] of String
      new_schema = TableSchema.new(schema.name, new_cols, pk_names)
      {new_sel_cols, aug_rows, new_schema}
    end

    private def compute_window_values(
      w : AST::WindowExpr,
      rows : Array(Row),
      schema : TableSchema,
      binder : ParamBinder
    ) : Array(Value)
      n = rows.size
      result = Array(Value).new(n, nil.as(Value))
      return result if n == 0

      # Build partition key string per row
      partition_groups = Hash(String, Array(Int32)).new
      rows.each_with_index do |row, i|
        key = w.partition_by.map { |pb| eval_expr(pb, row, schema, binder).inspect }.join(",")
        (partition_groups[key] ||= [] of Int32) << i
      end

      partition_groups.each do |_, indices|
        sorted = if w.order_by.any?
          indices.sort { |a, b|
            cmp = 0
            w.order_by.each do |ob_expr, asc|
              va = eval_expr(ob_expr, rows[a], schema, binder)
              vb = eval_expr(ob_expr, rows[b], schema, binder)
              cmp = compare_values(va, vb)
              cmp = -cmp unless asc
              break if cmp != 0
            end
            cmp
          }
        else
          indices.dup
        end

        # Determine frame: use explicit frame, or default based on presence of ORDER BY
        has_order = w.order_by.any?
        frame = w.frame

        case w.fn
        when "ROW_NUMBER"
          sorted.each_with_index { |idx, pos| result[idx] = (pos + 1).to_i64.as(Value) }

        when "RANK"
          last_key = nil
          last_rank = 0
          sorted.each_with_index do |idx, pos|
            cur_key = w.order_by.map { |ob_expr, _| eval_expr(ob_expr, rows[idx], schema, binder) }
            if last_key.nil? || !window_keys_equal?(cur_key, last_key.not_nil!)
              last_rank = pos + 1
              last_key = cur_key
            end
            result[idx] = last_rank.to_i64.as(Value)
          end

        when "DENSE_RANK"
          last_key = nil
          dense = 0
          sorted.each do |idx|
            cur_key = w.order_by.map { |ob_expr, _| eval_expr(ob_expr, rows[idx], schema, binder) }
            if last_key.nil? || !window_keys_equal?(cur_key, last_key.not_nil!)
              dense += 1
              last_key = cur_key
            end
            result[idx] = dense.to_i64.as(Value)
          end

        when "LAG", "LEAD"
          offset = w.fn_args.size >= 2 ? to_i64(eval_expr(w.fn_args[1], [] of Value, nil, binder)).to_i : 1
          offset = -offset if w.fn == "LEAD"
          sorted.each_with_index do |idx, pos|
            src_pos = pos - offset
            if src_pos >= 0 && src_pos < sorted.size
              src_idx = sorted[src_pos]
              val = w.fn_args.first? ? eval_expr(w.fn_args[0], rows[src_idx], schema, binder) : nil.as(Value)
              result[idx] = val
            else
              default_val = w.fn_args.size >= 3 ? eval_expr(w.fn_args[2], [] of Value, nil, binder) : nil.as(Value)
              result[idx] = default_val
            end
          end

        when "FIRST_VALUE"
          first_val = w.fn_args.first? ? eval_expr(w.fn_args[0], rows[sorted[0]], schema, binder) : nil.as(Value)
          sorted.each { |idx| result[idx] = first_val }

        when "LAST_VALUE"
          last_val = w.fn_args.first? ? eval_expr(w.fn_args[0], rows[sorted.last], schema, binder) : nil.as(Value)
          sorted.each { |idx| result[idx] = last_val }

        when "SUM", "AVG", "COUNT", "MIN", "MAX"
          running = if has_order && frame.nil?
            true   # default with ORDER BY: RANGE UNBOUNDED PRECEDING → CURRENT ROW (running)
          elsif f = frame
            # Explicit ROWS/RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW = running
            f.start_bound.bound_type.unbounded_preceding? && f.end_bound.bound_type.current_row?
          else
            false
          end
          if running
            acc_sum  = 0.0_f64
            acc_count = 0_i64
            acc_min : Value = nil
            acc_max : Value = nil
            sorted.each do |idx|
              val = w.fn_args.first?.try { |arg| eval_expr(arg, rows[idx], schema, binder) }
              unless val.nil?
                num = case val
                      when Int64   then val.to_f64
                      when Float64 then val
                      else 0.0_f64
                      end
                acc_sum += num
                acc_count += 1
                acc_min = val if acc_min.nil? || compare_values(val, acc_min) < 0
                acc_max = val if acc_max.nil? || compare_values(val, acc_max) > 0
              end
              result[idx] = case w.fn
              when "SUM"   then acc_count > 0 ? acc_sum.to_i64.as(Value) : nil.as(Value)
              when "AVG"   then acc_count > 0 ? (acc_sum / acc_count).as(Value) : nil.as(Value)
              when "COUNT" then acc_count.as(Value)
              when "MIN"   then acc_min
              when "MAX"   then acc_max
              else              nil.as(Value)
              end
            end
          else
            # Whole-partition aggregate
            agg_sum  = 0.0_f64
            agg_count = 0_i64
            agg_min : Value = nil
            agg_max : Value = nil
            sorted.each do |idx|
              val = w.fn_args.first?.try { |arg| eval_expr(arg, rows[idx], schema, binder) }
              unless val.nil?
                num = case val
                      when Int64   then val.to_f64
                      when Float64 then val
                      else 0.0_f64
                      end
                agg_sum += num
                agg_count += 1
                agg_min = val if agg_min.nil? || compare_values(val, agg_min) < 0
                agg_max = val if agg_max.nil? || compare_values(val, agg_max) > 0
              end
            end
            agg_result : Value = case w.fn
            when "SUM"   then agg_count > 0 ? agg_sum.to_i64.as(Value) : nil.as(Value)
            when "AVG"   then agg_count > 0 ? (agg_sum / agg_count).as(Value) : nil.as(Value)
            when "COUNT" then agg_count.as(Value)
            when "MIN"   then agg_min
            when "MAX"   then agg_max
            else              nil.as(Value)
            end
            sorted.each { |idx| result[idx] = agg_result }
          end

        when "NTILE"
          buckets = w.fn_args.first? ? to_i64(eval_expr(w.fn_args[0], [] of Value, nil, binder)).to_i : 1
          buckets = [buckets, 1].max
          size = sorted.size
          sorted.each_with_index do |idx, pos|
            bucket = (pos * buckets // size) + 1
            result[idx] = bucket.to_i64.as(Value)
          end

        else
          raise DB::Error.new("unsupported window function: #{w.fn}")
        end
      end

      result
    end

    private def window_keys_equal?(a : Array(Value), b : Array(Value)) : Bool
      return false if a.size != b.size
      a.each_with_index { |v, i| return false if compare_values(v, b[i]) != 0 }
      true
    end

    private def project_cols(
      sel_cols : Array(AST::SelCol),
      rows : Array(Row),
      schema : TableSchema,
      binder : ParamBinder
    ) : {Array(String), Array(Row)}
      # Pre-compute window functions if any sel_col uses one
      sel_cols, rows, schema = resolve_window_functions(sel_cols, rows, schema, binder) if sel_cols.any? { |sc| sc.expr.is_a?(AST::WindowExpr) }
      col_names = sel_cols.map { |sc| sel_col_name(sc) }
      result_rows = rows.map do |row|
        sel_cols.flat_map do |sc|
          if sc.expr.is_a?(AST::Star)
            row.dup
          elsif qs = sc.expr.as?(AST::QualifiedStar)
            # t.* → select only columns prefixed by "t."
            prefix = "#{qs.tbl}."
            filtered_cols = schema.cols.select { |c| c.name.starts_with?(prefix) }
            filtered_cols.map { |c| row[schema.col_index(c.name)] }
          else
            [eval_expr(sc.expr, row, schema, binder)]
          end
        end
      end
      if sel_cols.size == 1 && sel_cols[0].expr.is_a?(AST::Star)
        col_names = schema.cols.map { |c|
          dot = c.name.index('.')
          dot ? c.name[(dot + 1)..] : c.name
        }
      elsif sel_cols.size == 1 && (qs = sel_cols[0].expr.as?(AST::QualifiedStar))
        prefix = "#{qs.tbl}."
        col_names = schema.cols.select { |c| c.name.starts_with?(prefix) }.map { |c|
          dot = c.name.index('.')
          dot ? c.name[(dot + 1)..] : c.name
        }
      end
      {col_names, result_rows}
    end

    private def col_ref_index(col_ref : AST::ColRef, schema : TableSchema) : Int32
      if tbl = col_ref.tbl
        qualified = "#{tbl}.#{col_ref.col}"
        if idx = schema.cols.index { |c| c.name == qualified }
          return idx
        end
      end
      schema.col_index(col_ref.col)
    end

    private def sel_col_name(sc : AST::SelCol) : String
      sc.alias_name || expr_to_col_name(sc.expr)
    end

    private def expr_to_col_name(expr : AST::Expr) : String
      case expr
      when AST::ColRef        then expr.col
      when AST::QualifiedStar then "#{expr.tbl}.*"
      when AST::FnCall       then "#{expr.fn}(#{expr.args.map { |a| expr_to_col_name(a) }.join(",")})"
      when AST::WindowExpr   then "#{expr.fn}()"
      when AST::Star        then "*"
      when AST::Lit         then expr.val.inspect
      else                        "?"
      end
    end

    private def eval_expr(expr : AST::Expr, row : Row, schema : TableSchema?, binder : ParamBinder, excluded_row : Row? = nil) : Value
      case expr
      when AST::Lit    then expr.val
      when AST::Param  then binder.get(expr.idx)
      when AST::ColRef then eval_col_ref(expr, row, schema, excluded_row)
      when AST::BinOp  then eval_binop(expr, row, schema, binder, excluded_row)
      when AST::IsNull then eval_is_null(expr, row, schema, binder, excluded_row)
      when AST::FnCall then eval_fn_call(expr, row, schema, binder, excluded_row)
      when AST::Star   then nil
      when AST::InExpr
        val = eval_expr(expr.expr, row, schema, binder, excluded_row)
        members = if sq = expr.subquery
          result = exec_select(sq, binder)
          result.is_a?(QueryResult) ? result.rows.map(&.first?) : [] of Value
        else
          expr.values.map { |e| eval_expr(e, row, schema, binder, excluded_row) }
        end
        is_in = members.any? { |m| !val.nil? && compare_values(val, m) == 0 }
        (expr.negated ? !is_in : is_in).as(Value)
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

    private def eval_col_ref(expr : AST::ColRef, row : Row, schema : TableSchema?, excluded_row : Row? = nil) : Value
      # excluded.col — reference the incoming insert row (for ON CONFLICT DO UPDATE SET)
      if expr.tbl == "excluded" && excluded_row && schema
        idx = schema.col_index(expr.col)
        return excluded_row[idx]
      end

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
      # Table-qualified reference (e.g. a.id) — for join schemas where cols are named "a.id"
      if tbl = expr.tbl
        qualified = "#{tbl}.#{expr.col}"
        if idx = s.cols.index { |c| c.name == qualified }
          return row[idx]
        end
      end
      idx = s.col_index(expr.col)
      row[idx]
    end

    private def eval_binop(expr : AST::BinOp, row : Row, schema : TableSchema?, binder : ParamBinder, excluded_row : Row? = nil) : Value
      case expr.op
      when AST::BinOp::Op::And
        l = eval_expr(expr.left, row, schema, binder, excluded_row)
        return false.as(Value) unless truthy?(l)
        eval_expr(expr.right, row, schema, binder, excluded_row)
      when AST::BinOp::Op::Or
        l = eval_expr(expr.left, row, schema, binder, excluded_row)
        return l if truthy?(l)
        eval_expr(expr.right, row, schema, binder, excluded_row)
      when AST::BinOp::Op::Concat
        l = eval_expr(expr.left, row, schema, binder, excluded_row)
        r = eval_expr(expr.right, row, schema, binder, excluded_row)
        return nil.as(Value) if l.nil? || r.nil?
        (l.to_s + r.to_s).as(Value)
      else
        l = eval_expr(expr.left, row, schema, binder, excluded_row)
        r = eval_expr(expr.right, row, schema, binder, excluded_row)
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

    private def eval_is_null(expr : AST::IsNull, row : Row, schema : TableSchema?, binder : ParamBinder, excluded_row : Row? = nil) : Value
      val = eval_expr(expr.expr, row, schema, binder, excluded_row)
      (expr.negated ? !val.nil? : val.nil?).as(Value)
    end

    private def eval_fn_call(expr : AST::FnCall, row : Row, schema : TableSchema?, binder : ParamBinder, excluded_row : Row? = nil) : Value
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
      when "MAX", "MIN", "SUM", "AVG"
        nil
      when "COALESCE", "IFNULL"
        expr.args.each do |arg|
          v = eval_expr(arg, row, schema, binder, excluded_row)
          return v unless v.nil?
        end
        nil.as(Value)
      when "NULLIF"
        a = eval_expr(expr.args[0], row, schema, binder, excluded_row)
        b = eval_expr(expr.args[1], row, schema, binder, excluded_row)
        compare_values(a, b) == 0 ? nil.as(Value) : a
      when "STRFTIME"
        return nil.as(Value) if expr.args.size < 2
        fmt = eval_expr(expr.args[0], row, schema, binder, excluded_row)
        return nil.as(Value) unless fmt.is_a?(String)
        t = eval_timespec(expr.args[1..], row, schema, binder, excluded_row)
        return nil.as(Value) if t.nil?
        t.to_s(fmt).as(Value)
      when "DATETIME", "DATE"
        return nil.as(Value) if expr.args.empty?
        t = eval_timespec(expr.args, row, schema, binder, excluded_row)
        return nil.as(Value) if t.nil?
        fmt = expr.fn == "DATE" ? "%Y-%m-%d" : "%Y-%m-%dT%H:%M:%S"
        t.to_s(fmt).as(Value)
      when "CAST"
        if arg = expr.args[0]?
          eval_expr(arg, row, schema, binder, excluded_row)
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

    private def deep_copy_tables : Hash(String, Table)
      result = Hash(String, Table).new
      @tables.each { |k, v| result[k] = v.deep_copy }
      result
    end

    private def eval_timespec(args : Array(AST::Expr), row : Row, schema : TableSchema?, binder : ParamBinder, excluded_row : Row? = nil) : Time?
      return nil if args.empty?
      base = eval_expr(args[0], row, schema, binder, excluded_row)
      return nil unless base.is_a?(String)
      t = if base.downcase == "now"
        Time.utc
      else
        parsed = begin
          Time.parse(base, "%Y-%m-%dT%H:%M:%S", Time::Location::UTC)
        rescue
          begin
            Time.parse(base, "%Y-%m-%d %H:%M:%S", Time::Location::UTC)
          rescue
            Time.parse(base, "%Y-%m-%d", Time::Location::UTC) rescue return nil
          end
        end
        parsed
      end
      args[1..].each do |mod_arg|
        mod = eval_expr(mod_arg, row, schema, binder, excluded_row)
        next unless mod.is_a?(String)
        t = apply_time_modifier(t, mod) || return nil
      end
      t
    end

    private def apply_time_modifier(t : Time, mod : String) : Time?
      if m = mod.strip.match(/^([+-]?\d+)\s+(seconds?|minutes?|hours?|days?|months?|years?)$/i)
        n = m[1].to_i64
        unit = m[2].downcase
        unit = unit.rstrip('s') if unit.ends_with?("s") && unit != "s"
        case unit
        when "second" then t + n.seconds
        when "minute" then t + n.minutes
        when "hour"   then t + n.hours
        when "day"    then t + n.days
        when "month"  then t.shift(months: n.to_i)
        when "year"   then t.shift(years: n.to_i)
        else nil
        end
      else
        nil
      end
    end

    private def expr_to_sql(expr : AST::Expr) : String
      case expr
      when AST::Lit
        case expr.val
        when Nil     then "NULL"
        when String  then "'#{expr.val.as(String).gsub("'", "''")}'"
        when Int64   then expr.val.to_s
        when Float64 then expr.val.to_s
        when Bool    then expr.val.as(Bool) ? "1" : "0"
        else "NULL"
        end
      when AST::FnCall
        "#{expr.fn}(#{expr.args.map { |a| expr_to_sql(a) }.join(",")})"
      when AST::ColRef
        expr.tbl ? "#{expr.tbl}.#{expr.col}" : expr.col
      when AST::BinOp
        op = case expr.op
        when .concat? then "||"
        when .and?    then " AND "
        when .or?     then " OR "
        when .eq?     then "="
        when .ne?     then "!="
        when .lt?     then "<"
        when .gt?     then ">"
        when .le?     then "<="
        when .ge?     then ">="
        else "?"
        end
        "(#{expr_to_sql(expr.left)}#{op}#{expr_to_sql(expr.right)})"
      else
        "NULL"
      end
    end
  end
end
