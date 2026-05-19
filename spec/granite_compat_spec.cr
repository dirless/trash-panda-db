require "./spec_helper"

# Tests that validate the exact SQL patterns emitted by Granite ORM's SQLite adapter.
# Granite uses double-quoted identifiers, `?` placeholders, LAST_INSERT_ROWID(),
# and VARCHAR for timestamp columns.
#
# Reference: amberframework/granite src/adapter/sqlite.cr and src/adapter/base.cr
describe "Granite ORM compatibility" do
  describe "schema creation" do
    it "handles Granite's CREATE TABLE IF NOT EXISTS with NOT NULL primary key" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" (
            "id"         INTEGER NOT NULL,
            "name"       VARCHAR,
            "email"      VARCHAR,
            "created_at" VARCHAR,
            "updated_at" VARCHAR,
            PRIMARY KEY ("id")
          )
        SQL
        db.scalar(%|SELECT COUNT(*) FROM "users"|).should eq 0
      end
    end

    it "handles AUTO Int64 column type (INTEGER NOT NULL, no explicit PK constraint)" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "posts" (
            "id"    INTEGER NOT NULL,
            "title" VARCHAR,
            PRIMARY KEY ("id")
          )
        SQL
        db.exec %|INSERT INTO "posts" ("title") VALUES (?)|, "Hello"
        db.exec %|INSERT INTO "posts" ("title") VALUES (?)|, "World"
        db.scalar(%|SELECT MAX("id") FROM "posts"|).should eq 2
      end
    end
  end

  describe "INSERT" do
    it "inserts a row and returns LAST_INSERT_ROWID()" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" (
            "id" INTEGER NOT NULL PRIMARY KEY,
            "name" VARCHAR,
            "email" VARCHAR,
            "created_at" VARCHAR,
            "updated_at" VARCHAR
          )
        SQL

        now = Time.utc.to_s
        db.exec(
          %|INSERT INTO "users" ("name", "email", "created_at", "updated_at") VALUES (?, ?, ?, ?)|,
          "Alice", "alice@example.com", now, now
        )
        last_id = db.scalar("SELECT LAST_INSERT_ROWID()").as?(Int64)
        last_id.should eq 1
      end
    end

    it "LAST_INSERT_ROWID() increments correctly across multiple inserts" do
      with_db do |db|
        db.exec "CREATE TABLE IF NOT EXISTS \"t\" (\"id\" INTEGER NOT NULL PRIMARY KEY, \"val\" VARCHAR)"
        db.exec %|INSERT INTO "t" ("val") VALUES (?)|, "a"
        db.exec %|INSERT INTO "t" ("val") VALUES (?)|, "b"
        db.exec %|INSERT INTO "t" ("val") VALUES (?)|, "c"
        db.scalar("SELECT LAST_INSERT_ROWID()").as?(Int64).should eq 3
      end
    end

    it "INSERT OR REPLACE (Granite import with update_on_duplicate)" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" (
            "id" INTEGER NOT NULL PRIMARY KEY,
            "name" VARCHAR,
            "email" VARCHAR
          )
        SQL
        db.exec %|INSERT INTO "users" ("id", "name", "email") VALUES (?, ?, ?)|, 1, "Alice", "a@example.com"
        db.exec %|INSERT OR REPLACE INTO "users" ("id", "name", "email") VALUES (?, ?, ?), (?, ?, ?), (?, ?, ?)|,
          1, "AliceV2", "av2@example.com",
          2, "Bob", "bob@example.com",
          3, "Charlie", "charlie@example.com"

        db.scalar(%|SELECT "name" FROM "users" WHERE "id" = ?|, 1).should eq "AliceV2"
        db.scalar(%|SELECT COUNT(*) FROM "users"|).should eq 3
      end
    end

    it "INSERT OR IGNORE (Granite import with ignore_on_duplicate)" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" (
            "id" INTEGER NOT NULL PRIMARY KEY,
            "name" VARCHAR
          )
        SQL
        db.exec %|INSERT INTO "users" ("id", "name") VALUES (?, ?)|, 1, "Alice"
        db.exec %|INSERT OR IGNORE INTO "users" ("id", "name") VALUES (?, ?)|, 1, "AliceV2"
        db.scalar(%|SELECT "name" FROM "users" WHERE "id" = ?|, 1).should eq "Alice"
      end
    end
  end

  describe "SELECT" do
    it "SELECT with double-quoted table and column names" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" (
            "id" INTEGER NOT NULL PRIMARY KEY,
            "name" VARCHAR,
            "email" VARCHAR
          )
        SQL
        db.exec %|INSERT INTO "users" ("id", "name", "email") VALUES (?, ?, ?)|, 1, "Alice", "alice@example.com"

        db.query(%|SELECT "users"."id", "users"."name", "users"."email" FROM "users"|) do |rs|
          rs.move_next.should be_true
          rs.read(Int64).should eq 1_i64
          rs.read(String).should eq "Alice"
          rs.read(String).should eq "alice@example.com"
        end
      end
    end

    it "SELECT with WHERE using double-quoted column name" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" (
            "id" INTEGER NOT NULL PRIMARY KEY,
            "name" VARCHAR
          )
        SQL
        db.exec %|INSERT INTO "users" ("id", "name") VALUES (?, ?)|, 1, "Alice"
        db.exec %|INSERT INTO "users" ("id", "name") VALUES (?, ?)|, 2, "Bob"

        db.scalar(%|SELECT "name" FROM "users" WHERE "users"."id"=?|, 1).should eq "Alice"
      end
    end

    it "SELECT with ORDER BY, LIMIT, OFFSET (Granite .all pagination)" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" (
            "id" INTEGER NOT NULL PRIMARY KEY,
            "name" VARCHAR
          )
        SQL
        (1..10).each { |i| db.exec %|INSERT INTO "users" ("id", "name") VALUES (?, ?)|, i, "User#{i}" }

        ids = [] of Int64
        db.query(%|SELECT "users"."id" FROM "users" ORDER BY "id" ASC LIMIT ? OFFSET ?|, 3, 4) do |rs|
          rs.each { ids << rs.read(Int64) }
        end
        ids.should eq [5_i64, 6_i64, 7_i64]
      end
    end

    it "SELECT COUNT(*) (Granite .count)" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" ("id" INTEGER NOT NULL PRIMARY KEY, "name" VARCHAR)
        SQL
        3.times { |i| db.exec %|INSERT INTO "users" ("id", "name") VALUES (?, ?)|, i + 1, "U#{i}" }
        db.scalar(%|SELECT COUNT(*) FROM "users"|).should eq 3
      end
    end

    it "SELECT COUNT(*) with WHERE (Granite .count with clause)" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" ("id" INTEGER NOT NULL PRIMARY KEY, "name" VARCHAR)
        SQL
        db.exec %|INSERT INTO "users" ("id", "name") VALUES (?, ?)|, 1, "Alice"
        db.exec %|INSERT INTO "users" ("id", "name") VALUES (?, ?)|, 2, "Bob"
        db.exec %|INSERT INTO "users" ("id", "name") VALUES (?, ?)|, 3, "Alice"
        db.scalar(%|SELECT COUNT(*) FROM "users" WHERE "name" = ?|, "Alice").should eq 2
      end
    end

    it "SELECT EXISTS(SELECT 1 ...) (Granite .exists?)" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" ("id" INTEGER NOT NULL PRIMARY KEY, "name" VARCHAR)
        SQL
        db.exec %|INSERT INTO "users" ("id", "name") VALUES (?, ?)|, 1, "Alice"
        existing = db.query_one?(
          %|SELECT EXISTS(SELECT 1 FROM "users" WHERE "id" = ?)|,
          1, as: Bool
        )
        existing.should be_truthy

        missing = db.query_one?(
          %|SELECT EXISTS(SELECT 1 FROM "users" WHERE "id" = ?)|,
          999, as: Bool
        )
        missing.should be_falsey
      end
    end
  end

  describe "UPDATE" do
    it "updates via Granite's pattern: SET col=? WHERE pk=?" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" (
            "id" INTEGER NOT NULL PRIMARY KEY,
            "name" VARCHAR,
            "email" VARCHAR,
            "updated_at" VARCHAR
          )
        SQL
        now = Time.utc.to_s
        db.exec %|INSERT INTO "users" ("id", "name", "email", "updated_at") VALUES (?, ?, ?, ?)|,
          1, "Alice", "old@example.com", now

        new_time = (Time.utc + 1.second).to_s
        db.exec %|UPDATE "users" SET "name"=?, "email"=?, "updated_at"=? WHERE "id"=?|,
          "Alicia", "new@example.com", new_time, 1

        db.query(%|SELECT "name", "email" FROM "users" WHERE "id" = ?|, 1) do |rs|
          rs.move_next
          rs.read(String).should eq "Alicia"
          rs.read(String).should eq "new@example.com"
        end
      end
    end
  end

  describe "DELETE" do
    it "deletes via Granite's pattern: WHERE pk=?" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" ("id" INTEGER NOT NULL PRIMARY KEY, "name" VARCHAR)
        SQL
        db.exec %|INSERT INTO "users" ("id", "name") VALUES (?, ?)|, 1, "Alice"
        db.exec %|DELETE FROM "users" WHERE "id"=?|, 1
        db.scalar(%|SELECT COUNT(*) FROM "users"|).should eq 0
      end
    end
  end

  describe "timestamp round-trip" do
    it "Granite stores timestamps as VARCHAR — round-trips correctly" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "events" (
            "id"         INTEGER NOT NULL PRIMARY KEY,
            "created_at" VARCHAR,
            "updated_at" VARCHAR
          )
        SQL
        t = Time.utc(2025, 3, 14, 9, 26, 53)
        db.exec %|INSERT INTO "events" ("id", "created_at", "updated_at") VALUES (?, ?, ?)|,
          1, t.to_s, t.to_s

        raw = db.scalar(%|SELECT "created_at" FROM "events" WHERE "id" = ?|, 1).as?(String)
        raw.should eq t.to_s
      end
    end
  end

  describe "multi-row batch import" do
    it "INSERT OR REPLACE with multiple value tuples (Granite .import)" do
      with_db do |db|
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS "users" (
            "id" INTEGER NOT NULL PRIMARY KEY,
            "name" VARCHAR,
            "email" VARCHAR
          )
        SQL

        db.exec(
          %|INSERT OR REPLACE INTO "users" ("id", "name", "email") VALUES (?, ?, ?),(?, ?, ?),(?, ?, ?)|,
          1, "Alice", "a@example.com",
          2, "Bob", "b@example.com",
          3, "Charlie", "c@example.com"
        )
        db.scalar(%|SELECT COUNT(*) FROM "users"|).should eq 3
        db.scalar(%|SELECT "name" FROM "users" WHERE "id" = ?|, 2).should eq "Bob"
      end
    end
  end
end
