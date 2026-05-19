require "./spec_helper"

describe Driver do
  it "should register trashpanda name" do
    DB.driver_class("trashpanda").should eq(TrashPandaDB::Driver)
  end

  pending "should get filename from uri" do
    # SQLite3 uses percent-encoded :memory: URIs — trashpanda uses trashpanda::memory: instead
  end

  it "should use database option as file to open" do
    with_db do |db|
      db.checkout.should be_a(TrashPandaDB::Connection)
      File.exists?(DB_FILENAME).should be_true
    end
  end
end
