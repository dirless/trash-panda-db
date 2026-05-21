require "./spec_helper"

DIRLESS_DB = "./test_dirless.tpdb"

private def open_dirless_db(&block : DB::Database ->)
  DB.open "trashpanda:#{DIRLESS_DB}", &block
end

private def cleanup_dirless
  File.delete(DIRLESS_DB) rescue nil
  File.delete("#{DIRLESS_DB}-wal") rescue nil
end

describe "dirless-backend compatibility" do
  before_each { cleanup_dirless }
  after_each  { cleanup_dirless }

  it "PRAGMA statements are accepted as no-ops" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "PRAGMA foreign_keys = ON"
      db.exec "PRAGMA journal_mode = WAL"
      db.exec "PRAGMA synchronous = NORMAL"
      db.exec "PRAGMA busy_timeout = 5000"
    end
  end

  it "BEGIN IMMEDIATE / DEFERRED / EXCLUSIVE are accepted" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "BEGIN IMMEDIATE"
      db.exec "ROLLBACK"
      db.exec "BEGIN DEFERRED"
      db.exec "ROLLBACK"
      db.exec "BEGIN EXCLUSIVE"
      db.exec "ROLLBACK"
    end
  end

  it "|| string concatenation works" do
    DB.open("trashpanda::memory:") do |db|
      v = db.scalar("SELECT 'hello' || ' ' || 'world'").as(String)
      v.should eq "hello world"
    end
  end

  it "|| concat with parameters works" do
    DB.open("trashpanda::memory:") do |db|
      v = db.scalar("SELECT '-' || ? || ' seconds'", 30_i64).as(String)
      v.should eq "-30 seconds"
    end
  end

  it "strftime('now') returns a formatted timestamp" do
    DB.open("trashpanda::memory:") do |db|
      v = db.scalar("SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now')").as(String)
      v.should match /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
    end
  end

  it "DATETIME('now') returns an ISO timestamp" do
    DB.open("trashpanda::memory:") do |db|
      v = db.scalar("SELECT DATETIME('now')").as(String)
      v.should match /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/
    end
  end

  it "DATETIME with modifier subtracts seconds" do
    DB.open("trashpanda::memory:") do |db|
      v = db.scalar("SELECT DATETIME('now', '-30 seconds')").as(String)
      v.should match /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/
    end
  end

  it "DATETIME with concat parameter modifier works" do
    DB.open("trashpanda::memory:") do |db|
      v = db.scalar("SELECT DATETIME('now', '-' || ? || ' seconds')", 30_i64).as(String)
      v.should match /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/
    end
  end

  it "COALESCE returns first non-null value" do
    DB.open("trashpanda::memory:") do |db|
      v = db.scalar("SELECT COALESCE(NULL, NULL, 42)").as(Int64)
      v.should eq 42_i64
    end
  end

  it "COALESCE(MAX(col), fallback) on empty table returns fallback" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)"
      v = db.scalar("SELECT COALESCE(MAX(n), 1000) FROM t").as(Int64)
      v.should eq 1000_i64
    end
  end

  it "COALESCE(MAX(col), fallback) on populated table returns max" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)"
      db.exec "INSERT INTO t (id, n) VALUES (1, 5)"
      db.exec "INSERT INTO t (id, n) VALUES (2, 99)"
      db.exec "INSERT INTO t (id, n) VALUES (3, 3)"
      v = db.scalar("SELECT COALESCE(MAX(n), 0) FROM t").as(Int64)
      v.should eq 99_i64
    end
  end

  it "IFNULL returns second arg when first is null" do
    DB.open("trashpanda::memory:") do |db|
      v = db.scalar("SELECT IFNULL(NULL, 'fallback')").as(String)
      v.should eq "fallback"
    end
  end

  it "NULLIF returns null when both args are equal" do
    DB.open("trashpanda::memory:") do |db|
      v = db.scalar("SELECT NULLIF(1, 1)")
      v.should be_nil
    end
  end

  it "NULLIF returns first arg when args differ" do
    DB.open("trashpanda::memory:") do |db|
      v = db.scalar("SELECT NULLIF(1, 2)").as(Int64)
      v.should eq 1_i64
    end
  end

  it "CHECK and REFERENCES in CREATE TABLE do not cause parse errors" do
    DB.open("trashpanda::memory:") do |db|
      db.exec <<-SQL
        CREATE TABLE users (
          id   TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          age  INTEGER CHECK (age > 0)
        )
      SQL
      db.exec <<-SQL
        CREATE TABLE posts (
          id      INTEGER PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id),
          title   TEXT NOT NULL
        )
      SQL
      db.exec "INSERT INTO users (id, name, age) VALUES ('u1', 'Alice', 30)"
      db.exec "INSERT INTO posts (id, user_id, title) VALUES (1, 'u1', 'Hello')"
      n = db.scalar("SELECT COUNT(*) FROM posts").as(Int64)
      n.should eq 1_i64
    end
  end

  it "DEFAULT '' is applied on INSERT when column is omitted" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, gecos TEXT NOT NULL DEFAULT '')"
      db.exec "INSERT INTO t (id) VALUES (1)"
      v = db.scalar("SELECT gecos FROM t WHERE id = 1").as(String)
      v.should eq ""
    end
  end

  it "DEFAULT with literal string is applied on INSERT" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, shell TEXT NOT NULL DEFAULT '/bin/bash')"
      db.exec "INSERT INTO t (id) VALUES (1)"
      v = db.scalar("SELECT shell FROM t WHERE id = 1").as(String)
      v.should eq "/bin/bash"
    end
  end

  it "DEFAULT (strftime(...)) is applied on INSERT" do
    DB.open("trashpanda::memory:") do |db|
      db.exec <<-SQL
        CREATE TABLE t (
          id         INTEGER PRIMARY KEY,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        )
      SQL
      db.exec "INSERT INTO t (id) VALUES (1)"
      v = db.scalar("SELECT created_at FROM t WHERE id = 1").as(String)
      v.should match /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
    end
  end

  it "DEFAULT is persisted and restored after reopen" do
    open_dirless_db do |db|
      db.exec <<-SQL
        CREATE TABLE t (
          id   INTEGER PRIMARY KEY,
          note TEXT NOT NULL DEFAULT 'hello'
        )
      SQL
    end

    open_dirless_db do |db|
      db.exec "INSERT INTO t (id) VALUES (1)"
      v = db.scalar("SELECT note FROM t WHERE id = 1").as(String)
      v.should eq "hello"
    end
  end

  it "ON CONFLICT DO UPDATE upserts an existing row" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "CREATE TABLE settings (key TEXT, value TEXT NOT NULL)"
      db.exec "INSERT INTO settings (key, value) VALUES ('x', 'old')"
      sql = "INSERT INTO settings (key, value) VALUES ('x', 'new') ON CONFLICT (key) DO UPDATE SET value = ?"
      db.exec sql, "updated"
      v = db.scalar("SELECT value FROM settings WHERE key = 'x'").as(String)
      v.should eq "updated"
    end
  end

  it "ON CONFLICT DO UPDATE inserts when no conflict exists" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "CREATE TABLE settings (key TEXT, value TEXT NOT NULL)"
      sql = "INSERT INTO settings (key, value) VALUES ('newkey', 'val') ON CONFLICT (key) DO UPDATE SET value = ?"
      db.exec sql, "val"
      v = db.scalar("SELECT value FROM settings WHERE key = 'newkey'").as(String)
      v.should eq "val"
    end
  end

  it "ON CONFLICT DO UPDATE with compound key" do
    DB.open("trashpanda::memory:") do |db|
      db.exec <<-SQL
        CREATE TABLE memberships (
          user_id    TEXT NOT NULL,
          group_id   TEXT NOT NULL,
          deleted_at TEXT
        )
      SQL
      db.exec "INSERT INTO memberships (user_id, group_id, deleted_at) VALUES ('u1', 'g1', 'old')"
      db.exec <<-SQL
        INSERT INTO memberships (user_id, group_id, deleted_at)
        VALUES ('u1', 'g1', 'new')
        ON CONFLICT (user_id, group_id) DO UPDATE SET deleted_at = NULL
      SQL
      v = db.scalar("SELECT deleted_at FROM memberships WHERE user_id = 'u1' AND group_id = 'g1'")
      v.should be_nil
    end
  end

  it "INSERT OR IGNORE does not raise on duplicate rowid" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"
      db.exec "INSERT INTO t (id, v) VALUES (1, 'a')"
      db.exec "INSERT OR IGNORE INTO t (id, v) VALUES (1, 'b')"
      v = db.scalar("SELECT v FROM t WHERE id = 1").as(String)
      v.should eq "a"
    end
  end

  it "simulates the dirless schema migrations without errors" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "PRAGMA foreign_keys = ON"
      db.exec "PRAGMA journal_mode = WAL"

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version    INTEGER PRIMARY KEY,
          applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        )
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS users (
          id          TEXT    PRIMARY KEY,
          username    TEXT    NOT NULL UNIQUE,
          uid         INTEGER NOT NULL UNIQUE,
          gid         INTEGER NOT NULL,
          gecos       TEXT    NOT NULL DEFAULT '',
          home        TEXT    NOT NULL,
          shell       TEXT    NOT NULL DEFAULT '/bin/bash',
          provider    TEXT    NOT NULL,
          provider_id TEXT    NOT NULL,
          created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
          updated_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
          deleted_at  TEXT
        )
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS groups (
          id          TEXT    PRIMARY KEY,
          name        TEXT    NOT NULL UNIQUE,
          gid         INTEGER NOT NULL UNIQUE,
          provider    TEXT    NOT NULL,
          provider_id TEXT    NOT NULL,
          created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
          updated_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
          deleted_at  TEXT
        )
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS group_memberships (
          user_id    TEXT NOT NULL REFERENCES users(id),
          group_id   TEXT NOT NULL REFERENCES groups(id),
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
          deleted_at TEXT,
          PRIMARY KEY (user_id, group_id)
        )
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS settings (
          key        TEXT PRIMARY KEY,
          value      TEXT NOT NULL,
          updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        )
      SQL

      db.exec <<-SQL
        INSERT OR IGNORE INTO settings (key, value) VALUES
          ('uid_start',     '40000'),
          ('default_shell', '/bin/bash'),
          ('home_prefix',   '/home')
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS lease (
          singleton_lock INTEGER PRIMARY KEY CHECK (singleton_lock = 1),
          syncer_id      TEXT    NOT NULL,
          acquired_at    TEXT    NOT NULL,
          expires_at     TEXT    NOT NULL
        )
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS agent_heartbeats (
          agent_id     TEXT PRIMARY KEY,
          hostname     TEXT NOT NULL,
          last_seen_at TEXT NOT NULL
        )
      SQL

      # verify settings seeded
      count = db.scalar("SELECT COUNT(*) FROM settings").as(Int64)
      count.should eq 3_i64

      # verify DEFAULT from subquery
      db.exec "INSERT INTO schema_migrations (version) VALUES (1)"
      applied = db.scalar("SELECT applied_at FROM schema_migrations WHERE version = 1").as(String)
      applied.should match /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
    end
  end

  it "ON CONFLICT DO UPDATE with excluded.col reference" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT)"
      db.exec "INSERT INTO settings (key, value) VALUES ('x', 'old')"
      sql = "INSERT INTO settings (key, value) VALUES ('x', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value"
      db.exec sql, "new"
      v = db.scalar("SELECT value FROM settings WHERE key = 'x'").as(String)
      v.should eq "new"
    end
  end

  it "ON CONFLICT DO UPDATE with excluded.col and strftime" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT)"
      db.exec "INSERT INTO settings (key, value) VALUES ('x', 'old')"
      sql = <<-SQL
        INSERT INTO settings (key, value) VALUES ('x', ?)
        ON CONFLICT (key) DO UPDATE SET
          value = excluded.value,
          updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      SQL
      db.exec sql, "new"
      v = db.scalar("SELECT value FROM settings WHERE key = 'x'").as(String)
      v.should eq "new"
      v = db.scalar("SELECT updated_at FROM settings WHERE key = 'x'").as(String)
      v.should match /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
    end
  end

  it "t.* in a JOIN selects only that table's columns" do
    DB.open("trashpanda::memory:") do |db|
      db.exec "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "CREATE TABLE memberships (user_id INTEGER, group_id INTEGER)"
      db.exec "INSERT INTO users VALUES (1, 'Alice')"
      db.exec "INSERT INTO memberships VALUES (1, 99)"
      db.query("SELECT u.* FROM users u JOIN memberships m ON m.user_id = u.id WHERE m.group_id = 99") do |rs|
        rs.move_next
        rs.read(Int64).should eq 1_i64
        rs.read(String).should eq "Alice"
      end
    end
  end
end