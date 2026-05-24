require "uri"
require "./storage/pager"

class TrashPandaDB::Connection < DB::Connection
  getter sql_db : SQL::Database
  getter pager : Storage::Pager?
  @tx_depth : Int32 = 0

  def initialize(options : ::DB::Connection::Options, @uri : URI, @sql_db : SQL::Database, @pager : Storage::Pager? = nil)
    super(options)
  end

  def in_transaction? : Bool
    @tx_depth > 0
  end

  def build_prepared_statement(query) : Statement
    Statement.new(self, query)
  end

  def build_unprepared_statement(query) : Statement
    Statement.new(self, query)
  end

  def do_close
    # Intentionally do NOT close the shared pager here. All connections in
    # the pool share the same pager (created once by ConnectionBuilder).
    # When Crystal's DB pool evicts an idle connection it calls do_close —
    # closing the pager would destroy the database for every remaining
    # connection in the pool.  The pager is flushed after each statement via
    # sync_to_storage and will be cleaned up when the process exits.
  end

  # Auto-commit: flush WAL after each non-transaction statement
  def sync_to_storage
    if pager = @pager
      puts "DEBUG: sync_to_storage, in_txn=#{@sql_db.in_transaction?}, dirty=#{pager.wal.@dirty.size}" if ENV["DEBUG"]?
      unless @sql_db.in_transaction?
        puts "DEBUG: calling pager.commit" if ENV["DEBUG"]?
        pager.commit
        puts "DEBUG: after commit, committed=#{pager.wal.@committed.size}" if ENV["DEBUG"]?
      end
    end
  end

  def perform_begin_transaction
    @tx_depth += 1
    @sql_db.begin_transaction
  end

  def perform_commit_transaction
    @sql_db.commit_transaction
    @tx_depth -= 1
    if pager = @pager
      pager.commit unless @sql_db.in_transaction?
    end
  end

  def perform_rollback_transaction
    @sql_db.rollback_transaction
    @tx_depth -= 1
  end

  def perform_create_savepoint(name)
    @tx_depth += 1
    @sql_db.create_savepoint(name)
  end

  def perform_release_savepoint(name)
    @sql_db.release_savepoint(name)
    @tx_depth -= 1
  end

  def perform_rollback_savepoint(name)
    @sql_db.rollback_to_savepoint(name)
    @tx_depth -= 1
  end
end
