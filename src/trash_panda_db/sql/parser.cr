module TrashPandaDB::SQL
  class Parser
    def initialize(@tokens : Array(Token))
      @pos = 0
      @param_idx = 0
    end

    def parse : AST::Stmt
      stmt = parse_stmt
      consume(TokenKind::Semicolon) if peek.kind == TokenKind::Semicolon
      stmt
    end

    private def parse_stmt : AST::Stmt
      case peek.kind
      when TokenKind::KwCreate   then parse_create
      when TokenKind::KwAlter    then parse_alter
      when TokenKind::KwInsert   then parse_insert
      when TokenKind::KwSelect   then parse_select
      when TokenKind::KwUpdate   then parse_update
      when TokenKind::KwDelete   then parse_delete
      when TokenKind::KwDrop     then parse_drop
      when TokenKind::KwVacuum   then advance; AST::Vacuum.new
      when TokenKind::KwBegin
        advance
        if peek.kind == TokenKind::Ident && {"IMMEDIATE", "DEFERRED", "EXCLUSIVE"}.includes?(peek.value.upcase)
          advance
        end
        AST::Begin.new
      when TokenKind::KwCommit   then advance; AST::Commit.new
      when TokenKind::KwRollback then parse_rollback
      when TokenKind::KwSavepoint    then parse_savepoint
      when TokenKind::KwRelease      then parse_release_savepoint
      when TokenKind::Ident
        if peek.value.upcase == "PRAGMA"
          while peek.kind != TokenKind::Semicolon && peek.kind != TokenKind::Eof
            advance
          end
          return AST::Pragma.new
        end
        raise "unexpected token '#{peek.value}' (#{peek.kind})"
      else
        raise "unexpected token '#{peek.value}' (#{peek.kind})"
      end
    end

    # ── CREATE TABLE / CREATE INDEX ───────────────────────────────────────────

    private def parse_create : AST::Stmt
      consume(TokenKind::KwCreate)
      unique = false
      if peek.kind == TokenKind::Ident && peek.value.upcase == "UNIQUE"
        advance
        unique = true
      end
      if peek.kind == TokenKind::KwIndex
        advance
        parse_create_index(unique)
      else
        raise "expected INDEX or TABLE after CREATE#{unique ? " UNIQUE" : ""}" if unique
        expect_ident("TABLE")
        parse_create_table_body
      end
    end

    private def parse_create_table : AST::CreateTable
      consume(TokenKind::KwCreate)
      expect_ident("TABLE")
      parse_create_table_body
    end

    private def parse_create_table_body : AST::CreateTable
      if_not_exists = false
      if peek.kind == TokenKind::KwIf
        advance
        expect_ident("NOT")
        expect_ident("EXISTS")
        if_not_exists = true
      end
      tbl = consume_ident
      consume(TokenKind::LParen)

      col_defs = Array(AST::ColDef).new
      table_pk = Array(String).new

      loop do
        if peek.kind == TokenKind::KwPrimary
          # table-level PRIMARY KEY(col, ...)
          advance
          consume_kw(TokenKind::KwKey)
          consume(TokenKind::LParen)
          table_pk << consume_ident
          while peek.kind == TokenKind::Comma
            advance
            table_pk << consume_ident
          end
          consume(TokenKind::RParen)
        else
          col_defs << parse_col_def
        end
        break if peek.kind != TokenKind::Comma
        advance
        break if peek.kind == TokenKind::RParen
      end

      consume(TokenKind::RParen)
      AST::CreateTable.new(tbl, if_not_exists, col_defs, table_pk)
    end

    private def parse_col_def : AST::ColDef
      name = consume_ident
      type_str = consume_ident  # VARCHAR, INTEGER, TEXT, BLOB, REAL, etc.
      # absorb any extra type tokens (e.g., "VARCHAR(255)")
      if peek.kind == TokenKind::LParen
        advance
        while peek.kind != TokenKind::RParen && peek.kind != TokenKind::Eof
          advance
        end
        consume(TokenKind::RParen)
      end

      not_null = false
      pk = false
      default_expr : AST::Expr? = nil

      loop do
        case peek.kind
        when TokenKind::KwNull
          advance
        when TokenKind::KwNot
          advance
          consume_kw(TokenKind::KwNull)
          not_null = true
        when TokenKind::KwPrimary
          advance
          consume_kw(TokenKind::KwKey)
          pk = true
        when TokenKind::Ident
          case peek.value.upcase
          when "DEFAULT"
            advance
            default_expr = parse_expr
          when "CHECK"
            advance
            skip_paren_group if peek.kind == TokenKind::LParen
          when "REFERENCES"
            advance
            consume_ident  # referenced table name
            skip_paren_group if peek.kind == TokenKind::LParen
          when "UNIQUE", "AUTOINCREMENT"
            advance
          else
            break
          end
        else
          break
        end
      end

      AST::ColDef.new(name, type_str, not_null, pk, default_expr)
    end

    private def skip_paren_group : Nil
      consume(TokenKind::LParen)
      depth = 1
      while depth > 0 && peek.kind != TokenKind::Eof
        depth += 1 if peek.kind == TokenKind::LParen
        depth -= 1 if peek.kind == TokenKind::RParen
        advance
      end
    end

    # ── INSERT ────────────────────────────────────────────────────────────────

    private def parse_insert : AST::Insert
      consume(TokenKind::KwInsert)

      conflict = AST::Insert::Conflict::Abort
      if peek.kind == TokenKind::KwOr
        advance
        case peek.kind
        when TokenKind::KwReplace then advance; conflict = AST::Insert::Conflict::Replace
        when TokenKind::KwIgnore  then advance; conflict = AST::Insert::Conflict::Ignore
        else raise "expected REPLACE or IGNORE after INSERT OR"
        end
      end

      consume(TokenKind::KwInto)
      tbl = consume_ident

      col_names = Array(String).new
      if peek.kind == TokenKind::LParen
        advance
        col_names << consume_ident
        while peek.kind == TokenKind::Comma
          advance
          col_names << consume_ident
        end
        consume(TokenKind::RParen)
      end

      expect_ident("VALUES")

      value_rows = Array(Array(AST::Expr)).new
      loop do
        consume(TokenKind::LParen)
        row = [parse_expr]
        while peek.kind == TokenKind::Comma
          advance
          row << parse_expr
        end
        consume(TokenKind::RParen)
        value_rows << row
        break if peek.kind != TokenKind::Comma
        advance
      end

      on_conflict_cols = [] of String
      on_conflict_updates = [] of Tuple(String, AST::Expr)
      if peek.kind == TokenKind::KwOn
        advance  # ON
        expect_ident("CONFLICT")
        consume(TokenKind::LParen)
        on_conflict_cols << consume_ident
        while peek.kind == TokenKind::Comma
          advance; on_conflict_cols << consume_ident
        end
        consume(TokenKind::RParen)
        expect_ident("DO")
        consume(TokenKind::KwUpdate)
        consume(TokenKind::KwSet)
        loop do
          col = consume_ident
          consume(TokenKind::Eq)
          on_conflict_updates << {col, parse_expr}
          break if peek.kind != TokenKind::Comma
          advance
        end
      end

      AST::Insert.new(conflict, tbl, col_names, value_rows, on_conflict_cols, on_conflict_updates)
    end

    def parse_expr_public : AST::Expr
      parse_expr
    end

    # ── SELECT ────────────────────────────────────────────────────────────────

    private def parse_select : AST::Select
      consume(TokenKind::KwSelect)

      distinct = false
      if peek.kind == TokenKind::KwDistinct
        advance
        distinct = true
      end

      sel_cols = parse_select_cols
      from_tbl = nil
      from_alias = nil
      from_subquery = nil
      joins = Array(AST::JoinClause).new

      if peek.kind == TokenKind::KwFrom
        advance
        if peek.kind == TokenKind::LParen
          # Sub-select in FROM: (SELECT ...) AS alias
          advance
          from_subquery = parse_select
          consume(TokenKind::RParen)
          advance if peek.kind == TokenKind::KwAs
          from_alias = consume_ident
        else
          from_tbl = consume_ident
          from_alias = parse_table_alias

          # Parse JOIN clauses
          loop do
            join_type = case peek.kind
            when TokenKind::KwJoin
              advance
              AST::JoinClause::Type::Inner
            when TokenKind::KwInner
              advance
              consume_kw(TokenKind::KwJoin)
              AST::JoinClause::Type::Inner
            when TokenKind::KwLeft
              advance
              advance if peek.kind == TokenKind::KwOuter
              consume_kw(TokenKind::KwJoin)
              AST::JoinClause::Type::Left
            when TokenKind::KwCross
              advance
              consume_kw(TokenKind::KwJoin)
              AST::JoinClause::Type::Cross
            else
              break
            end
            j_tbl = consume_ident
            j_alias = parse_table_alias
            on_expr = nil
            if peek.kind == TokenKind::KwOn
              advance
              on_expr = parse_expr
            end
            joins << AST::JoinClause.new(join_type, j_tbl, j_alias, on_expr)
          end
        end
      end

      where_expr = nil
      if peek.kind == TokenKind::KwWhere
        advance
        where_expr = parse_expr
      end

      group_by = Array(AST::Expr).new
      if peek.kind == TokenKind::KwGroup
        advance
        consume_kw(TokenKind::KwBy)
        group_by << parse_expr
        while peek.kind == TokenKind::Comma
          advance
          group_by << parse_expr
        end
      end

      having_expr = nil
      if peek.kind == TokenKind::KwHaving
        advance
        having_expr = parse_expr
      end

      order_by = Array(Tuple(AST::ColRef, Bool)).new
      if peek.kind == TokenKind::KwOrder
        advance
        consume_kw(TokenKind::KwBy)
        order_by << parse_order_col
        while peek.kind == TokenKind::Comma
          advance
          order_by << parse_order_col
        end
      end

      limit_expr = nil
      offset_expr = nil
      if peek.kind == TokenKind::KwLimit
        advance
        limit_expr = parse_expr
        if peek.kind == TokenKind::KwOffset
          advance
          offset_expr = parse_expr
        end
      end

      AST::Select.new(sel_cols, distinct, from_tbl, from_alias, from_subquery, joins, where_expr, group_by, having_expr, order_by, limit_expr, offset_expr)
    end

    private def parse_order_col : Tuple(AST::ColRef, Bool)
      name = consume_ident
      col_ref = if peek.kind == TokenKind::Dot
        advance
        AST::ColRef.new(name, consume_ident)
      else
        AST::ColRef.new(nil, name)
      end
      asc = true
      if peek.kind == TokenKind::KwAsc
        advance
      elsif peek.kind == TokenKind::KwDesc
        advance; asc = false
      end
      {col_ref, asc}
    end

    # Consumes an optional table alias (AS alias or bare identifier).
    private def parse_table_alias : String?
      if peek.kind == TokenKind::KwAs
        advance
        return consume_ident
      end
      # Only consume a plain Ident as an implicit alias — never a keyword.
      if peek.kind == TokenKind::Ident
        return advance.value
      end
      nil
    end

    private def parse_select_cols : Array(AST::SelCol)
      cols = Array(AST::SelCol).new

      # handle bare * first
      if peek.kind == TokenKind::Star
        advance
        cols << AST::SelCol.new(AST::Star.new, nil)
        return cols
      end

      cols << parse_one_sel_col
      while peek.kind == TokenKind::Comma
        advance
        cols << parse_one_sel_col
      end
      cols
    end

    private def parse_one_sel_col : AST::SelCol
      expr = parse_sel_expr
      alias_name = nil
      if peek.kind == TokenKind::KwAs
        advance
        alias_name = consume_ident
      elsif peek.kind == TokenKind::Ident && !next_is_comma_or_from_or_end
        # bare alias without AS
        alias_name = advance.value
      end
      AST::SelCol.new(expr, alias_name)
    end

    # Parses an expression in a SELECT column position (allows function calls and table.col)
    private def parse_sel_expr : AST::Expr
      if peek.kind == TokenKind::Star
        advance
        return AST::Star.new
      end
      if peek.kind == TokenKind::Ident || peek.kind == TokenKind::QuotedIdent
        quoted = peek.kind == TokenKind::QuotedIdent
        name = peek.value
        advance
        # function call? (only for bare identifiers — "foo"(...) is not a call)
        if !quoted && peek.kind == TokenKind::LParen
          advance
          args = Array(AST::Expr).new
          if peek.kind == TokenKind::Star
            advance
            args << AST::Star.new
          elsif peek.kind != TokenKind::RParen
            if peek.kind == TokenKind::KwSelect
              # EXISTS(SELECT ...)
              sub = parse_select
              consume(TokenKind::RParen)
              return AST::FnCall.new(name.upcase, [AST::Subquery.new(sub).as(AST::Expr)])
            end
            args << parse_expr
            while peek.kind == TokenKind::Comma
              advance
              args << parse_expr
            end
          end
          # CAST(expr AS type)
          consume_cast_as if name.compare("CAST", case_insensitive: true) == 0
          consume(TokenKind::RParen)
          return AST::FnCall.new(name.upcase, args)
        end
        # table.column?
        if peek.kind == TokenKind::Dot
          advance
          if peek.kind == TokenKind::Star
            advance
            return AST::QualifiedStar.new(name)
          end
          col = consume_ident
          return AST::ColRef.new(name, col, quoted)
        end
        return AST::ColRef.new(nil, name, quoted)
      end
      parse_expr
    end

    # ── UPDATE ────────────────────────────────────────────────────────────────

    private def parse_update : AST::Update
      consume(TokenKind::KwUpdate)
      tbl = consume_ident
      consume_kw(TokenKind::KwSet)

      assignments = Array(Tuple(String, AST::Expr)).new
      col = consume_ident
      consume(TokenKind::Eq)
      val = parse_expr
      assignments << {col, val}
      while peek.kind == TokenKind::Comma
        advance
        c2 = consume_ident
        consume(TokenKind::Eq)
        v2 = parse_expr
        assignments << {c2, v2}
      end

      where_expr = nil
      if peek.kind == TokenKind::KwWhere
        advance
        where_expr = parse_expr
      end

      AST::Update.new(tbl, assignments, where_expr)
    end

    # ── DELETE ────────────────────────────────────────────────────────────────

    private def parse_delete : AST::Delete
      consume(TokenKind::KwDelete)
      consume(TokenKind::KwFrom)
      tbl = consume_ident
      where_expr = nil
      if peek.kind == TokenKind::KwWhere
        advance
        where_expr = parse_expr
      end
      AST::Delete.new(tbl, where_expr)
    end

    # ── CREATE INDEX ──────────────────────────────────────────────────────────

    private def parse_create_index(unique : Bool) : AST::CreateIndex
      if_not_exists = false
      if peek.kind == TokenKind::KwIf
        advance
        expect_ident("NOT")
        expect_ident("EXISTS")
        if_not_exists = true
      end
      name = consume_ident
      consume_kw(TokenKind::KwOn)
      tbl = consume_ident
      consume(TokenKind::LParen)
      cols = [consume_ident]
      while peek.kind == TokenKind::Comma
        advance
        cols << consume_ident
      end
      consume(TokenKind::RParen)
      AST::CreateIndex.new(name, if_not_exists, tbl, cols, unique)
    end

    # ── DROP TABLE / DROP INDEX ───────────────────────────────────────────────

    private def parse_drop : AST::Stmt
      consume(TokenKind::KwDrop)
      if peek.kind == TokenKind::KwIndex
        advance
        parse_drop_index_body
      else
        consume_kw(TokenKind::KwTable)
        parse_drop_table_body
      end
    end

    private def parse_drop_table : AST::DropTable
      consume(TokenKind::KwDrop)
      consume(TokenKind::KwTable)
      parse_drop_table_body
    end

    private def parse_drop_table_body : AST::DropTable
      if_exists = false
      if peek.kind == TokenKind::KwIf
        advance
        expect_ident("EXISTS")
        if_exists = true
      end
      tbl = consume_ident
      AST::DropTable.new(tbl, if_exists)
    end

    private def parse_drop_index_body : AST::DropIndex
      if_exists = false
      if peek.kind == TokenKind::KwIf
        advance
        expect_ident("EXISTS")
        if_exists = true
      end
      name = consume_ident
      AST::DropIndex.new(name, if_exists)
    end

    # ── ALTER TABLE ───────────────────────────────────────────────────────────

    private def parse_alter : AST::AlterTable
      consume(TokenKind::KwAlter)
      expect_ident("TABLE")
      tbl = consume_ident
      cmd = parse_alter_cmd
      AST::AlterTable.new(tbl, cmd)
    end

    private def parse_alter_cmd : AST::AlterCmd
      if peek.kind == TokenKind::Ident && peek.value.upcase == "ADD"
        advance
        # optional COLUMN keyword
        advance if peek.kind == TokenKind::Ident && peek.value.upcase == "COLUMN"
        col_def = parse_col_def
        return AST::AlterAddColumn.new(col_def)
      end

      if peek.kind == TokenKind::KwDrop
        advance
        # optional COLUMN keyword
        advance if peek.kind == TokenKind::Ident && peek.value.upcase == "COLUMN"
        col = consume_ident
        return AST::AlterDropColumn.new(col)
      end

      if peek.kind == TokenKind::Ident && peek.value.upcase == "RENAME"
        advance
        if peek.kind == TokenKind::KwTo
          advance
          new_name = consume_ident
          return AST::AlterRenameTo.new(new_name)
        end
        # optional COLUMN keyword
        advance if peek.kind == TokenKind::Ident && peek.value.upcase == "COLUMN"
        old_col = consume_ident
        consume_kw(TokenKind::KwTo)
        new_col = consume_ident
        return AST::AlterRenameColumn.new(old_col, new_col)
      end

      raise "expected ADD, DROP, or RENAME after ALTER TABLE #{peek.value}"
    end

    # ── ROLLBACK / SAVEPOINT ──────────────────────────────────────────────────

    private def parse_rollback : AST::Stmt
      consume(TokenKind::KwRollback)
      if peek.kind == TokenKind::KwTo
        advance
        # optional SAVEPOINT keyword
        advance if peek.kind == TokenKind::KwSavepoint
        name = consume_ident
        return AST::RollbackTo.new(name)
      end
      AST::Rollback.new
    end

    private def parse_savepoint : AST::Savepoint
      consume(TokenKind::KwSavepoint)
      AST::Savepoint.new(consume_ident)
    end

    private def parse_release_savepoint : AST::ReleaseSavepoint
      consume(TokenKind::KwRelease)
      advance if peek.kind == TokenKind::KwSavepoint  # optional SAVEPOINT keyword
      AST::ReleaseSavepoint.new(consume_ident)
    end

    # ── Expressions ───────────────────────────────────────────────────────────

    private def parse_expr : AST::Expr
      parse_or
    end

    private def parse_or : AST::Expr
      left = parse_and
      while peek.kind == TokenKind::KwOr
        advance
        right = parse_and
        left = AST::BinOp.new(AST::BinOp::Op::Or, left, right)
      end
      left
    end

    private def parse_and : AST::Expr
      left = parse_concat
      while peek.kind == TokenKind::KwAnd
        advance
        right = parse_concat
        left = AST::BinOp.new(AST::BinOp::Op::And, left, right)
      end
      left
    end

    private def parse_concat : AST::Expr
      left = parse_comparison
      while peek.kind == TokenKind::Pipe
        advance
        right = parse_comparison
        left = AST::BinOp.new(AST::BinOp::Op::Concat, left, right)
      end
      left
    end

    private def parse_comparison : AST::Expr
      left = parse_primary
      case peek.kind
      when TokenKind::Eq
        advance; AST::BinOp.new(AST::BinOp::Op::Eq, left, parse_primary)
      when TokenKind::Ne
        advance; AST::BinOp.new(AST::BinOp::Op::Ne, left, parse_primary)
      when TokenKind::Lt
        advance; AST::BinOp.new(AST::BinOp::Op::Lt, left, parse_primary)
      when TokenKind::Gt
        advance; AST::BinOp.new(AST::BinOp::Op::Gt, left, parse_primary)
      when TokenKind::Le
        advance; AST::BinOp.new(AST::BinOp::Op::Le, left, parse_primary)
      when TokenKind::Ge
        advance; AST::BinOp.new(AST::BinOp::Op::Ge, left, parse_primary)
      when TokenKind::KwIs
        advance
        if peek.kind == TokenKind::KwNot
          advance
          consume_kw(TokenKind::KwNull)
          AST::IsNull.new(left, negated: true)
        else
          consume_kw(TokenKind::KwNull)
          AST::IsNull.new(left, negated: false)
        end
      when TokenKind::KwBetween
        advance
        lo = parse_primary
        consume_kw(TokenKind::KwAnd)
        hi = parse_primary
        AST::BinOp.new(
          AST::BinOp::Op::And,
          AST::BinOp.new(AST::BinOp::Op::Ge, left, lo),
          AST::BinOp.new(AST::BinOp::Op::Le, left, hi)
        )
      else
        left
      end
    end

    # Keywords safe to treat as bare column references in expression position.
    # Excludes NULL, NOT, AND, OR, IS and other tokens with dedicated expression semantics.
    private def keyword_col_in_expr?(kind : TokenKind) : Bool
      case kind
      when TokenKind::KwKey, TokenKind::KwSet, TokenKind::KwTable,
           TokenKind::KwLeft, TokenKind::KwJoin, TokenKind::KwInner,
           TokenKind::KwOuter, TokenKind::KwCross, TokenKind::KwGroup,
           TokenKind::KwHaving, TokenKind::KwIndex
        true
      else
        false
      end
    end

    private def parse_primary : AST::Expr
      # Keywords that are valid as column names in expression position (e.g. a column named "key")
      if keyword_col_in_expr?(peek.kind)
        name = peek.value
        advance
        if peek.kind == TokenKind::Dot
          col = consume_ident
          return AST::ColRef.new(name, col, false)
        end
        return AST::ColRef.new(nil, name, false)
      end
      case peek.kind
      when TokenKind::Question
        advance
        idx = @param_idx
        @param_idx += 1
        AST::Param.new(idx)
      when TokenKind::KwNull
        advance; AST::Lit.new(nil.as(Value))
      when TokenKind::IntLit
        tok = advance; AST::Lit.new(tok.value.to_i64.as(Value))
      when TokenKind::FloatLit
        tok = advance; AST::Lit.new(tok.value.to_f64.as(Value))
      when TokenKind::HexBlob
        tok = advance; AST::Lit.new(tok.value.to_slice.as(Value))
      when TokenKind::StrLit
        tok = advance; AST::Lit.new(tok.value.as(Value))
      when TokenKind::LParen
        advance
        expr = parse_expr
        consume(TokenKind::RParen)
        expr
      when TokenKind::Ident, TokenKind::QuotedIdent
        quoted = peek.kind == TokenKind::QuotedIdent
        name = peek.value
        advance
        if !quoted && peek.kind == TokenKind::LParen
          advance
          args = Array(AST::Expr).new
          if peek.kind == TokenKind::Star
            advance; args << AST::Star.new
          elsif peek.kind == TokenKind::KwSelect
            sub = parse_select
            consume(TokenKind::RParen)
            return AST::FnCall.new(name.upcase, [AST::Subquery.new(sub).as(AST::Expr)])
          elsif peek.kind != TokenKind::RParen
            args << parse_expr
            while peek.kind == TokenKind::Comma
              advance; args << parse_expr
            end
          end
          # CAST(expr AS type)
          consume_cast_as if name.compare("CAST", case_insensitive: true) == 0
          consume(TokenKind::RParen)
          AST::FnCall.new(name.upcase, args)
        elsif peek.kind == TokenKind::Dot
          advance
          col = consume_ident
          AST::ColRef.new(name, col, quoted)
        else
          AST::ColRef.new(nil, name, quoted)
        end
      else
        raise "unexpected token '#{peek.value}' (#{peek.kind}) while parsing expression"
      end
    end

    # ── Helpers ───────────────────────────────────────────────────────────────

    private def peek : Token
      @tokens[@pos]? || Token.new(TokenKind::Eof, "")
    end

    private def advance : Token
      tok = @tokens[@pos]
      @pos += 1
      tok
    end

    private def consume(kind : TokenKind) : Token
      tok = peek
      raise "expected #{kind} got #{tok.kind} ('#{tok.value}')" unless tok.kind == kind
      advance
    end

    private def consume_kw(kind : TokenKind) : Token
      consume(kind)
    end

    # Consumes an Ident or QuotedIdent token regardless of whether it was a keyword in another context.
    private def consume_ident : String
      tok = peek
      if tok.kind == TokenKind::Ident || tok.kind == TokenKind::QuotedIdent || keyword_as_ident?(tok.kind)
        advance
        tok.value
      else
        raise "expected identifier, got #{tok.kind} ('#{tok.value}')"
      end
    end

    # Allows certain keywords to appear as identifiers (e.g., table/column names
    # that happen to match a keyword like VALUES, INTEGER, VARCHAR).
    private def keyword_as_ident?(kind : TokenKind) : Bool
      case kind
      when TokenKind::KwKey, TokenKind::KwSet, TokenKind::KwTable,
           TokenKind::KwValues, TokenKind::KwFrom, TokenKind::KwWhere,
           TokenKind::KwOrder, TokenKind::KwBy, TokenKind::KwLimit,
           TokenKind::KwOffset, TokenKind::KwAsc, TokenKind::KwDesc,
           TokenKind::KwInsert, TokenKind::KwUpdate, TokenKind::KwDelete,
           TokenKind::KwSelect, TokenKind::KwCreate, TokenKind::KwAnd,
           TokenKind::KwOr, TokenKind::KwNot, TokenKind::KwNull,
           TokenKind::KwIs, TokenKind::KwAs, TokenKind::KwInto,
           TokenKind::KwPrimary, TokenKind::KwIgnore, TokenKind::KwReplace,
           TokenKind::KwRelease, TokenKind::KwSavepoint, TokenKind::KwRollback,
           TokenKind::KwCommit, TokenKind::KwBegin, TokenKind::KwTo,
           TokenKind::KwIf, TokenKind::KwOn, TokenKind::KwIndex,
           TokenKind::KwVacuum, TokenKind::KwJoin, TokenKind::KwLeft,
           TokenKind::KwInner, TokenKind::KwOuter, TokenKind::KwCross,
           TokenKind::KwBetween, TokenKind::KwGroup, TokenKind::KwHaving
        true
      else
        false
      end
    end

    private def expect_ident(word : String) : Nil
      tok = peek
      if tok.kind == TokenKind::Ident && tok.value.upcase == word
        advance
      elsif keyword_as_ident?(tok.kind) && tok.value.upcase == word
        advance
      else
        raise "expected '#{word}', got '#{tok.value}'"
      end
    end

    private def consume_cast_as : Nil
      return unless peek.kind == TokenKind::KwAs
      advance
      # consume the type name
      if peek.kind == TokenKind::Ident || keyword_as_ident?(peek.kind)
        advance
      end
    end

    private def next_is_comma_or_from_or_end : Bool
      case peek.kind
      when TokenKind::Comma, TokenKind::KwFrom, TokenKind::KwWhere,
           TokenKind::KwOrder, TokenKind::KwLimit, TokenKind::Semicolon,
           TokenKind::KwJoin, TokenKind::KwLeft, TokenKind::KwInner,
           TokenKind::KwCross, TokenKind::KwGroup, TokenKind::KwHaving,
           TokenKind::Eof
        true
      else
        false
      end
    end
  end
end
