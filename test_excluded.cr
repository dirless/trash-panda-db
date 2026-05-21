require "./src/trash_panda_db.cr"

sql = "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value"
lexer = TrashPandaDB::SQL::Lexer.new(sql).tokenize
parser = TrashPandaDB::SQL::Parser.new(lexer)

# Access the parser internals via reflection or just open it up for testing
class TrashPandaDB::SQL::Parser
  def parse_stmt_public
    parse_stmt
  end
end

stmt = parser.parse_stmt_public

if ins = stmt.as?(TrashPandaDB::SQL::AST::Insert)
  puts "Insert parsed"
  puts "on_conflict_cols: #{ins.on_conflict_cols.inspect}"
  puts "on_conflict_updates: #{ins.on_conflict_updates.inspect}"

  ins.on_conflict_updates.each do |col, expr|
    puts "  SET #{col} = #{expr.inspect}"
    if expr.is_a?(TrashPandaDB::SQL::AST::ColRef)
      puts "    -> ColRef tbl=#{expr.tbl}, col=#{expr.col}"
    end
  end
else
  puts "Not an Insert: #{stmt.class}"
end