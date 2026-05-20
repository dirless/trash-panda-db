require "./spec_helper"

describe TrashPandaDB::Storage::Catalog do
  it "round-trips a table schema" do
    # Create a temporary file-backed pager
    with_tmp_path do |path|
      pager = TrashPandaDB::Storage::Pager.new(path)

      # Create a table with schema
      cols = [
        TrashPandaDB::SQL::ColSchema.new("id", "INTEGER", false),
        TrashPandaDB::SQL::ColSchema.new("name", "TEXT", false),
      ]
      schema = TrashPandaDB::SQL::TableSchema.new("users", cols, ["id"])
      table = TrashPandaDB::SQL::Table.new(schema)
      table.next_rowid = 5_i64

      # Create a btree for this table
      root = TrashPandaDB::Storage::BTree.create(pager)
      btrees = {"users" => TrashPandaDB::Storage::BTree.new(pager, root)}

      # Save catalog
      TrashPandaDB::Storage::Catalog.save(pager, {"users" => table}, btrees)
      pager.commit

      # Reopen and load
      pager2 = TrashPandaDB::Storage::Pager.new(path)
      result = TrashPandaDB::Storage::Catalog.load(pager2)
      entries = result[:tables]

      entries.size.should eq 1
      entries.has_key?("users").should be_true
      info = entries["users"]
      info[:schema].name.should eq "users"
      info[:schema].cols.size.should eq 2
      info[:schema].cols[0].name.should eq "id"
      info[:schema].cols[1].name.should eq "name"
      info[:next_rowid].should eq 5_i64
      info[:root_page].should eq root

      pager.close
      pager2.close
    end
  end
end