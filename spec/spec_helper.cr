require "spec"
ENV["CRYSTAL_SPEC_CONTEXT"] = "1"
require "../src/trash_panda_db"

include TrashPandaDB

DB_FILENAME = "./test.tpdb"

def with_db(&block : DB::Database ->)
  File.delete(DB_FILENAME) rescue nil
  DB.open "trashpanda:#{DB_FILENAME}", &block
ensure
  File.delete(DB_FILENAME) rescue nil
  File.delete("#{DB_FILENAME}-wal") rescue nil
end

def with_cnn(&block : DB::Connection ->)
  File.delete(DB_FILENAME) rescue nil
  DB.connect "trashpanda:#{DB_FILENAME}", &block
ensure
  File.delete(DB_FILENAME) rescue nil
  File.delete("#{DB_FILENAME}-wal") rescue nil
end

def with_db(config, &block : DB::Database ->)
  uri = "trashpanda:#{config}"
  File.delete(DB_FILENAME) rescue nil
  DB.open uri, &block
ensure
  File.delete(DB_FILENAME) rescue nil
  File.delete("#{DB_FILENAME}-wal") rescue nil
end

def with_mem_db(&block : DB::Database ->)
  DB.open "trashpanda::memory:", &block
end
