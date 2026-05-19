require "uri"
require "./storage/pager"
require "./storage/serialization"

class TrashPandaDB::Connection < DB::Connection
  getter sql_db : SQL::Database
  getter pager : Storage::Pager?
  @tx_depth : Int32 = 0

  def initialize(options : ::DB::Connection::Options, @uri : URI, @sql_db : SQL::Database, @pager : Storage::Pager? = nil)
    super(options)
    replay_from_pager
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

  def sync_to_storage
    flush_to_pager
  end

  protected def do_close
    flush_to_pager
    if pager = @pager
      pager.close
    end
  end

  private def replay_from_pager
    return if @pager.nil?

    begin
      Storage::Serialization.deserialize(@sql_db, @pager.not_nil!)
    rescue ex
      # If deserialization fails, start with empty database
      # (could be new file or corrupted data)
      puts "Warning: Failed to replay database state: #{ex.message}" if ENV["DEBUG"]?
    end
  end

  private def flush_to_pager
    return if @pager.nil?

    begin
      Storage::Serialization.serialize(@sql_db, @pager.not_nil!)
      @pager.not_nil!.commit
    rescue ex : IndexError
      puts "Warning: Failed to flush database state (IndexError): #{ex.message}" if ENV["DEBUG"]?
      puts ex.backtrace.first(5) if ENV["DEBUG"]?
    rescue ex
      puts "Warning: Failed to flush database state: #{ex.message}" if ENV["DEBUG"]?
      puts ex.backtrace.first(5) if ENV["DEBUG"]?
    end
  end

  def perform_begin_transaction
    @tx_depth += 1
    @sql_db.begin_transaction
  end

  def perform_commit_transaction
    @sql_db.commit_transaction
    @tx_depth -= 1
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
