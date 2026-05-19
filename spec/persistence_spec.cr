require "./spec_helper"

PERSIST_DB = "./test_persist.tpdb"

private def open_persist_db(&block : DB::Database ->)
  DB.open "trashpanda:#{PERSIST_DB}", &block
end

private def cleanup_persist
  File.delete(PERSIST_DB) rescue nil
  File.delete("#{PERSIST_DB}-wal") rescue nil
end

describe "Persistence" do
  before_each { cleanup_persist }
  after_each  { cleanup_persist }

  it "saves and restores table data" do
    open_persist_db do |db|
      db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)"
      db.exec "INSERT INTO users (name, age) VALUES (?, ?)", "Alice", 30
      db.exec "INSERT INTO users (name, age) VALUES (?, ?)", "Bob", 25
      names = db.query_all "SELECT name FROM users", as: String
      names.should eq(["Alice", "Bob"])
    end

    open_persist_db do |db|
      names = db.query_all "SELECT name FROM users", as: String
      names.should eq(["Alice", "Bob"])
      ages = db.query_all "SELECT age FROM users ORDER BY name", as: Int32
      ages.should eq([30, 25])
    end
  end

  it "preserves autoincrement state" do
    open_persist_db do |db|
      db.exec "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO items (name) VALUES (?)", "item1"
      db.exec "INSERT INTO items (name) VALUES (?)", "item2"
      db.exec "INSERT INTO items (name) VALUES (?)", "item3"
      ids = db.query_all "SELECT id FROM items ORDER BY id", as: Int64
      ids.should eq([1_i64, 2_i64, 3_i64])
    end

    open_persist_db do |db|
      db.exec "INSERT INTO items (name) VALUES (?)", "item4"
      db.exec "INSERT INTO items (name) VALUES (?)", "item5"
      ids = db.query_all "SELECT id FROM items ORDER BY id", as: Int64
      ids.should eq([1_i64, 2_i64, 3_i64, 4_i64, 5_i64])
    end
  end

  it "handles multiple tables" do
    open_persist_db do |db|
      db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT, user_id INTEGER)"
      db.exec "INSERT INTO users (name) VALUES (?)", "Alice"
      db.exec "INSERT INTO posts (title, user_id) VALUES (?, ?)", "First post", 1
    end

    open_persist_db do |db|
      user_name = db.query_one "SELECT name FROM users", as: String
      user_name.should eq("Alice")
      post_title = db.query_one "SELECT title FROM posts", as: String
      post_title.should eq("First post")
    end
  end
end
