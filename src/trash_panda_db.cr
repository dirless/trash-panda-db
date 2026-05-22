require "db"

module TrashPandaDB
  VERSION = "0.1.0"

  alias Any = DB::Any | Int16 | Int8 | UInt32 | UInt16 | UInt8

  DATE_FORMAT_SUBSECOND = "%F %H:%M:%S.%L"
  DATE_FORMAT_SUBSECOND_Z = "%F %H:%M:%S.%L %z"
  DATE_FORMAT_SECOND    = "%F %H:%M:%S"

  TIME_ZONE = Time::Location::UTC
end

require "./trash_panda_db/storage/constants"
require "./trash_panda_db/storage/wal"
require "./trash_panda_db/storage/pager"
require "./trash_panda_db/storage/page_layout"
require "./trash_panda_db/sql/value"
require "./trash_panda_db/storage/row_codec"
require "./trash_panda_db/storage/btree"
require "./trash_panda_db/storage/catalog"
require "./trash_panda_db/sql/lexer"
require "./trash_panda_db/sql/ast"
require "./trash_panda_db/sql/parser"
require "./trash_panda_db/sql/database"
require "./trash_panda_db/result_set"
require "./trash_panda_db/statement"
require "./trash_panda_db/connection"
require "./trash_panda_db/driver"
require "./trash_panda_db/replication"
require "./trash_panda_db/raft_driver"
