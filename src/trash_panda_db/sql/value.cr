module TrashPandaDB::SQL
  # All scalar values stored in or returned from the database.
  alias Value = Nil | Bool | Int64 | Float64 | String | Bytes
  alias Row   = Array(Value)
end
