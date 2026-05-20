require "uri"
require "./storage/pager"

class TrashPandaDB::Driver < DB::Driver
  class ConnectionBuilder < ::DB::ConnectionBuilder
    # All connections in a pool share the same SQL::Database so data is visible
    # across connections (e.g., pool_spec multi-fiber writes).
    @shared_db : SQL::Database
    @pager : Storage::Pager

    def initialize(@options : ::DB::Connection::Options, @uri : URI)
      # Extract file path from URI
      # Format: "trashpanda:/path/to/file" or "trashpanda::memory:"
      path = if @uri.path == ":memory:" || @uri.path.empty? || @uri.path.ends_with?(":memory:")
               nil.as(String?)
             else
               @uri.path
             end

      @pager = Storage::Pager.new(path)
      @shared_db = SQL::Database.new(@pager)
    end

    def build : ::DB::Connection
      TrashPandaDB::Connection.new(@options, @uri, @shared_db, @pager)
    end
  end

  def connection_builder(uri : URI) : ::DB::ConnectionBuilder
    params = HTTP::Params.parse(uri.query || "")
    ConnectionBuilder.new(connection_options(params), uri)
  end
end

DB.register_driver "trashpanda", TrashPandaDB::Driver
