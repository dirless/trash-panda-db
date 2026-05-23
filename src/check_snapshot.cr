require "./trash_panda_db"

data_dir = ARGV[0]? || begin
  dirs = Dir.glob("/tmp/raft-data-hammer-*/raft_snapshot.db")
  abort "No snapshot files found" if dirs.empty?
  File.dirname(dirs.first)
end

snap_path   = File.join(data_dir, "raft_snapshot.db")
meta_path   = File.join(data_dir, "raft_snapshot.json")
state_path  = File.join(data_dir, "raft_state.json")
log_path    = File.join(data_dir, "raft_log.jsonl")

puts "=== Snapshot ==="
puts "  db: #{File.size(snap_path)} bytes" if File.exists?(snap_path)
puts "  json: #{JSON.parse(File.read(meta_path))}" if File.exists?(meta_path)

puts "\n=== State ==="
puts "  #{JSON.parse(File.read(state_path))}" if File.exists?(state_path)

puts "\n=== Log ==="
if File.exists?(log_path)
  lines = File.read_lines(log_path)
  puts "  entries: #{lines.size}"
  lines.first(2).each_with_index do |e, i|
    p = JSON.parse(e)
    puts "  [#{i}] idx=#{p["index"]} term=#{p["term"]} type=#{p["entry_type"]?} sql=#{p["sql"]?.to_s[0,80]}"
  end
  puts "  ..."
  lines.last(2).each_with_index do |e, i|
    idx = lines.size - 2 + i
    p = JSON.parse(e)
    puts "  [#{idx}] idx=#{p["index"]} term=#{p["term"]} type=#{p["entry_type"]?} sql=#{p["sql"]?.to_s[0,80]}"
  end
end

puts "\n=== Opening snapshot DB ==="
begin
  pager = TrashPandaDB::Storage::Pager.new(snap_path)
  db = TrashPandaDB::SQL::Database.new(pager)
  r = db.execute("SELECT name FROM __tpdb_catalog WHERE type = 'table'", [] of TrashPandaDB::SQL::Value)
  case r
  when TrashPandaDB::SQL::QueryResult
    puts "  Tables: #{r.rows.map { |row| row[0] }.join(", ")}"
  else
    puts "  Unexpected result type: #{r.class}"
  end

  begin
    c = db.execute("SELECT COUNT(*) FROM hammer", [] of TrashPandaDB::SQL::Value)
    case c
    when TrashPandaDB::SQL::QueryResult
      puts "  hammer rows: #{c.rows[0][0]}"
    else
      puts "  hammer: no rows returned"
    end
  rescue ex
    puts "  hammer: MISSING - #{ex.message}"
  end
rescue ex
  puts "  Error opening snapshot: #{ex.class}: #{ex.message}"
end