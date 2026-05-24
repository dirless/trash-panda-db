module TrashPandaDB::SQL
  enum TokenKind
    # Literals
    IntLit; FloatLit; StrLit; HexBlob
    # Names (quoted or bare identifier)
    Ident; QuotedIdent
    # Symbols
    Star; LParen; RParen; Comma; Dot; Eq; Ne; Lt; Gt; Le; Ge; Question; Semicolon; Pipe; Plus; Minus; Slash
    # Keywords
    KwAnd; KwAs; KwAsc; KwBegin; KwBetween; KwBy; KwCommit; KwCreate; KwCross
    KwAlter
    KwDelete; KwDesc; KwDistinct; KwDrop; KwFrom; KwGroup; KwHaving; KwIf; KwIgnore; KwIndex; KwInner
    KwIn; KwInsert; KwInto; KwIs; KwJoin; KwKey; KwLeft; KwLimit; KwNot
    KwNull; KwOffset; KwOn; KwOr; KwOrder; KwOuter; KwPrimary
    KwRelease; KwReplace; KwRollback; KwSavepoint; KwSelect; KwSet
    KwTable; KwTo; KwUpdate; KwVacuum; KwValues; KwWhere
    Eof
  end

  struct Token
    getter kind : TokenKind
    getter value : String

    def initialize(@kind : TokenKind, @value : String); end
  end

  class Lexer
    KEYWORDS = {
      "ALTER"     => TokenKind::KwAlter,
      "AND"       => TokenKind::KwAnd,
      "AS"        => TokenKind::KwAs,
      "ASC"       => TokenKind::KwAsc,
      "BEGIN"     => TokenKind::KwBegin,
      "BY"        => TokenKind::KwBy,
      "COMMIT"    => TokenKind::KwCommit,
      "CREATE"    => TokenKind::KwCreate,
      "DELETE"    => TokenKind::KwDelete,
      "DESC"      => TokenKind::KwDesc,
      "DISTINCT"  => TokenKind::KwDistinct,
      "DROP"      => TokenKind::KwDrop,
      "CROSS"     => TokenKind::KwCross,
      "BETWEEN"   => TokenKind::KwBetween,
      "FROM"      => TokenKind::KwFrom,
      "GROUP"     => TokenKind::KwGroup,
      "HAVING"    => TokenKind::KwHaving,
      "IF"        => TokenKind::KwIf,
      "IGNORE"    => TokenKind::KwIgnore,
      "INDEX"     => TokenKind::KwIndex,
      "INNER"     => TokenKind::KwInner,
      "IN"        => TokenKind::KwIn,
      "INSERT"    => TokenKind::KwInsert,
      "INTO"      => TokenKind::KwInto,
      "IS"        => TokenKind::KwIs,
      "JOIN"      => TokenKind::KwJoin,
      "KEY"       => TokenKind::KwKey,
      "LEFT"      => TokenKind::KwLeft,
      "LIMIT"     => TokenKind::KwLimit,
      "NOT"       => TokenKind::KwNot,
      "NULL"      => TokenKind::KwNull,
      "OFFSET"    => TokenKind::KwOffset,
      "ON"        => TokenKind::KwOn,
      "OR"        => TokenKind::KwOr,
      "ORDER"     => TokenKind::KwOrder,
      "OUTER"     => TokenKind::KwOuter,
      "PRIMARY"   => TokenKind::KwPrimary,
      "RELEASE"   => TokenKind::KwRelease,
      "REPLACE"   => TokenKind::KwReplace,
      "ROLLBACK"  => TokenKind::KwRollback,
      "SAVEPOINT" => TokenKind::KwSavepoint,
      "SELECT"    => TokenKind::KwSelect,
      "SET"       => TokenKind::KwSet,
      "TABLE"     => TokenKind::KwTable,
      "TO"        => TokenKind::KwTo,
      "UPDATE"    => TokenKind::KwUpdate,
      "VACUUM"    => TokenKind::KwVacuum,
      "VALUES"    => TokenKind::KwValues,
      "WHERE"     => TokenKind::KwWhere,
    }

    def initialize(@sql : String)
      @pos = 0
    end

    def tokenize : Array(Token)
      tokens = Array(Token).new
      loop do
        skip_ws
        break if @pos >= @sql.size
        tok = scan_one
        tokens << tok
        break if tok.kind == TokenKind::Eof
      end
      tokens << Token.new(TokenKind::Eof, "") unless tokens.last?.try(&.kind) == TokenKind::Eof
      tokens
    end

    private def skip_ws : Nil
      while @pos < @sql.size
        c = @sql[@pos]
        if c == ' ' || c == '\t' || c == '\n' || c == '\r'
          @pos += 1
        elsif c == '-' && @pos + 1 < @sql.size && @sql[@pos + 1] == '-'
          @pos += 2
          while @pos < @sql.size && @sql[@pos] != '\n'
            @pos += 1
          end
        else
          break
        end
      end
    end

    private def scan_one : Token
      return Token.new(TokenKind::Eof, "") if @pos >= @sql.size
      c = @sql[@pos]

      return scan_quoted_ident if c == '"'
      return scan_hex_blob      if (c == 'X' || c == 'x') && @pos + 1 < @sql.size && @sql[@pos + 1] == '\''
      return scan_string_lit   if c == '\''
      return scan_number       if c.ascii_number?

      # Negative numeric literals: '-' immediately followed by a digit.
      # Positive prefix '+' before a digit is treated as a Plus token so
      # that arithmetic expressions like INSTR(...) + 1 parse correctly.
      if c == '-' && @pos + 1 < @sql.size && @sql[@pos + 1].ascii_number?
        return scan_number
      end

      case c
      when '+' then @pos += 1; Token.new(TokenKind::Plus, "+")
      when '-' then @pos += 1; Token.new(TokenKind::Minus, "-")
      when '/' then @pos += 1; Token.new(TokenKind::Slash, "/")
      when '*' then @pos += 1; Token.new(TokenKind::Star, "*")
      when '(' then @pos += 1; Token.new(TokenKind::LParen, "(")
      when ')' then @pos += 1; Token.new(TokenKind::RParen, ")")
      when ',' then @pos += 1; Token.new(TokenKind::Comma, ",")
      when '.' then @pos += 1; Token.new(TokenKind::Dot, ".")
      when '?' then @pos += 1; Token.new(TokenKind::Question, "?")
      when ';' then @pos += 1; Token.new(TokenKind::Semicolon, ";")
      when '='
        @pos += 1
        Token.new(TokenKind::Eq, "=")
      when '!'
        raise "unexpected '!' at pos #{@pos}" if @pos + 1 >= @sql.size || @sql[@pos + 1] != '='
        @pos += 2
        Token.new(TokenKind::Ne, "!=")
      when '<'
        if @pos + 1 < @sql.size
          case @sql[@pos + 1]
          when '=' then @pos += 2; Token.new(TokenKind::Le, "<=")
          when '>' then @pos += 2; Token.new(TokenKind::Ne, "<>")
          else          @pos += 1; Token.new(TokenKind::Lt, "<")
          end
        else
          @pos += 1; Token.new(TokenKind::Lt, "<")
        end
      when '>'
        if @pos + 1 < @sql.size && @sql[@pos + 1] == '='
          @pos += 2; Token.new(TokenKind::Ge, ">=")
        else
          @pos += 1; Token.new(TokenKind::Gt, ">")
        end
      when '|'
        raise "expected '||' at pos #{@pos}" if @pos + 1 >= @sql.size || @sql[@pos + 1] != '|'
        @pos += 2; Token.new(TokenKind::Pipe, "||")
      else
        return scan_ident if c.ascii_letter? || c == '_'
        raise "unexpected character '#{c}' (#{c.ord}) at pos #{@pos} in: #{@sql}"
      end
    end

    private def scan_quoted_ident : Token
      @pos += 1  # skip "
      start = @pos
      while @pos < @sql.size && @sql[@pos] != '"'
        @pos += 1
      end
      value = @sql[start...@pos]
      @pos += 1  # skip closing "
      Token.new(TokenKind::QuotedIdent, value)
    end

    private def scan_hex_blob : Token
      @pos += 2  # skip X'
      start = @pos
      while @pos < @sql.size && @sql[@pos] != '\''
        @pos += 1
      end
      hex = @sql[start...@pos]
      @pos += 1  # skip closing '
      # Decode hex string to raw bytes string
      bytes = hex.hexbytes
      Token.new(TokenKind::HexBlob, String.new(bytes))
    end

    private def scan_string_lit : Token
      @pos += 1  # skip '
      buf = String::Builder.new
      while @pos < @sql.size
        c = @sql[@pos]
        if c == '\''
          if @pos + 1 < @sql.size && @sql[@pos + 1] == '\''
            buf << '\''
            @pos += 2
          else
            @pos += 1
            break
          end
        else
          buf << c
          @pos += 1
        end
      end
      Token.new(TokenKind::StrLit, buf.to_s)
    end

    private def scan_number : Token
      start = @pos
      @pos += 1 if @pos < @sql.size && (@sql[@pos] == '+' || @sql[@pos] == '-')
      while @pos < @sql.size && @sql[@pos].ascii_number?
        @pos += 1
      end
      if @pos < @sql.size && @sql[@pos] == '.'
        @pos += 1
        while @pos < @sql.size && @sql[@pos].ascii_number?
          @pos += 1
        end
        Token.new(TokenKind::FloatLit, @sql[start...@pos])
      else
        Token.new(TokenKind::IntLit, @sql[start...@pos])
      end
    end

    private def scan_ident : Token
      start = @pos
      while @pos < @sql.size && (@sql[@pos].ascii_alphanumeric? || @sql[@pos] == '_')
        @pos += 1
      end
      text = @sql[start...@pos]
      kind = KEYWORDS[text.upcase]? || TokenKind::Ident
      Token.new(kind, text)
    end
  end
end
