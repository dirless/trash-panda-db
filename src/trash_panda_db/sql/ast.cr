module TrashPandaDB::SQL
  module AST
    # ── Expressions ────────────────────────────────────────────────────────────

    abstract class Expr; end

    class Lit < Expr
      getter val : Value
      def initialize(@val : Value); end
    end

    # ? placeholder — carries its 0-based positional index assigned at parse time.
    class Param < Expr
      getter idx : Int32
      def initialize(@idx : Int32); end
    end

    class ColRef < Expr
      getter tbl : String?
      getter col : String
      getter quoted : Bool
      def initialize(@tbl : String?, @col : String, @quoted : Bool = false); end
    end

    # Any function call: COUNT(*), LAST_INSERT_ROWID(), EXISTS(subquery), ...
    class FnCall < Expr
      getter fn : String       # uppercased
      getter args : Array(Expr)
      getter cast_type : String?  # non-nil only for CAST(expr AS type)
      def initialize(@fn : String, @args : Array(Expr), @cast_type : String? = nil); end
    end

    class Star < Expr; end  # bare * in SELECT list

    class QualifiedStar < Expr
      getter tbl : String
      def initialize(@tbl : String); end
    end

    class BinOp < Expr
      enum Op; Eq; Ne; Lt; Gt; Le; Ge; And; Or; Concat; end
      getter op : Op
      getter left : Expr
      getter right : Expr
      def initialize(@op : Op, @left : Expr, @right : Expr); end
    end

    class IsNull < Expr
      getter expr : Expr
      getter negated : Bool  # IS NOT NULL
      def initialize(@expr : Expr, @negated : Bool); end
    end

    # expr [NOT] IN (val, val, ...) or expr [NOT] IN (SELECT ...)
    class InExpr < Expr
      getter expr : Expr
      getter values : Array(Expr)  # empty when subquery is set
      getter subquery : Select?
      getter negated : Bool
      def initialize(@expr : Expr, @values : Array(Expr), @subquery : Select?, @negated : Bool); end
    end

    class Subquery < Expr
      getter stmt : Select
      def initialize(@stmt : Select); end
    end

    # ── Window functions ───────────────────────────────────────────────────────

    enum WindowBoundType
      UnboundedPreceding; Preceding; CurrentRow; Following; UnboundedFollowing
    end

    struct WindowFrameBound
      getter bound_type : WindowBoundType
      getter offset : Int32
      def initialize(@bound_type : WindowBoundType, @offset : Int32 = 0); end
    end

    struct WindowFrame
      enum Mode; Rows; Range; end
      getter mode : Mode
      getter start_bound : WindowFrameBound
      getter end_bound : WindowFrameBound
      def initialize(@mode : Mode, @start_bound : WindowFrameBound, @end_bound : WindowFrameBound); end
    end

    class WindowExpr < Expr
      getter fn : String
      getter fn_args : Array(Expr)
      getter partition_by : Array(Expr)
      getter order_by : Array(Tuple(Expr, Bool))
      getter frame : WindowFrame?
      def initialize(@fn : String, @fn_args : Array(Expr), @partition_by : Array(Expr),
                     @order_by : Array(Tuple(Expr, Bool)), @frame : WindowFrame? = nil); end
    end

    # ── Statements ─────────────────────────────────────────────────────────────

    abstract class Stmt; end

    struct ColDef
      getter name : String
      getter type_str : String
      getter not_null : Bool
      getter pk : Bool
      getter unique : Bool
      getter default_expr : Expr?
      def initialize(@name : String, @type_str : String, @not_null : Bool, @pk : Bool, @unique : Bool = false, @default_expr : Expr? = nil); end
    end

    class CreateTable < Stmt
      getter tbl : String
      getter if_not_exists : Bool
      getter col_defs : Array(ColDef)
      getter table_pk : Array(String)  # column names from table-level PRIMARY KEY(...)
      def initialize(@tbl, @if_not_exists, @col_defs, @table_pk); end
    end

    class Insert < Stmt
      enum Conflict; Abort; Replace; Ignore; end
      getter conflict : Conflict
      getter tbl : String
      getter col_names : Array(String)
      getter value_rows : Array(Array(Expr))
      getter on_conflict_cols : Array(String)
      getter on_conflict_updates : Array(Tuple(String, Expr))
      getter on_conflict_where : Expr?
      getter returning : Array(SelCol)?
      def initialize(@conflict, @tbl, @col_names, @value_rows,
                     @on_conflict_cols = [] of String,
                     @on_conflict_updates = [] of Tuple(String, Expr),
                     @on_conflict_where = nil,
                     @returning = nil); end
    end

    record SelCol, expr : Expr, alias_name : String?

    struct JoinClause
      enum Type; Inner; Left; Cross; end
      getter join_type : Type
      getter tbl : String
      getter alias_name : String?
      getter on_expr : Expr?
      def initialize(@join_type : Type, @tbl : String, @alias_name : String?, @on_expr : Expr?); end
    end

    class Select < Stmt
      getter sel_cols : Array(SelCol)
      getter distinct : Bool
      getter from_tbl : String?
      getter from_alias : String?
      getter from_subquery : Select?
      getter joins : Array(JoinClause)
      getter where_expr : Expr?
      getter group_by : Array(Expr)
      getter having_expr : Expr?
      getter order_by : Array(Tuple(ColRef, Bool))  # (col, asc?)
      getter limit_expr : Expr?
      getter offset_expr : Expr?
      def initialize(@sel_cols, @distinct, @from_tbl, @from_alias, @from_subquery, @joins, @where_expr, @group_by, @having_expr, @order_by, @limit_expr, @offset_expr); end
    end

    class Update < Stmt
      getter tbl : String
      getter assignments : Array(Tuple(String, Expr))
      getter from_joins : Array(JoinClause)
      getter where_expr : Expr?
      getter returning : Array(SelCol)?
      def initialize(@tbl, @assignments, @from_joins, @where_expr, @returning = nil); end
    end

    class Delete < Stmt
      getter tbl : String
      getter using_joins : Array(JoinClause)
      getter where_expr : Expr?
      getter returning : Array(SelCol)?
      def initialize(@tbl, @using_joins, @where_expr, @returning = nil); end
    end

    class DropTable < Stmt
      getter tbl : String
      getter if_exists : Bool
      def initialize(@tbl, @if_exists); end
    end

    # ALTER TABLE sub-commands
    abstract class AlterCmd; end

    class AlterAddColumn < AlterCmd
      getter col_def : ColDef
      def initialize(@col_def : ColDef); end
    end

    class AlterDropColumn < AlterCmd
      getter col : String
      def initialize(@col : String); end
    end

    class AlterRenameColumn < AlterCmd
      getter old_col : String
      getter new_col : String
      def initialize(@old_col : String, @new_col : String); end
    end

    class AlterRenameTo < AlterCmd
      getter new_name : String
      def initialize(@new_name : String); end
    end

    class AlterTable < Stmt
      getter tbl : String
      getter cmd : AlterCmd
      def initialize(@tbl : String, @cmd : AlterCmd); end
    end

    class CreateIndex < Stmt
      getter name : String
      getter if_not_exists : Bool
      getter tbl : String
      getter cols : Array(String)
      getter unique : Bool
      def initialize(@name, @if_not_exists, @tbl, @cols, @unique); end
    end

    class DropIndex < Stmt
      getter name : String
      getter if_exists : Bool
      def initialize(@name, @if_exists); end
    end

    class Vacuum < Stmt; end
    class Pragma < Stmt; end

    class Explain < Stmt
      getter stmt : Select
      def initialize(@stmt : Select); end
    end

    class Begin < Stmt; end
    class Commit < Stmt; end
    class Rollback < Stmt; end

    class Savepoint < Stmt
      getter name : String
      def initialize(@name : String); end
    end

    class ReleaseSavepoint < Stmt
      getter name : String
      def initialize(@name : String); end
    end

    class RollbackTo < Stmt
      getter name : String
      def initialize(@name : String); end
    end
  end
end
