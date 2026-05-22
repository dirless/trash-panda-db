require "uri"
require "json"
require "socket"

# crystal-db driver that connects to a running trashpandadb Raft node via TCP.
#
# URL format: trashpandaraft://host:port
#
# Each statement creates a fresh TCP connection (the Raft server is
# request-per-connection). The DB::Database connection pool holds lightweight
# connection objects that carry only the URI; there is no persistent socket.
#
# Routing:
#   SELECT / EXPLAIN / PRAGMA  → "query"  (linearisable read from leader)
#   Everything else            → "propose" (write, forwarded to leader)
#
# Transactions (BEGIN/COMMIT/ROLLBACK) are forwarded via "propose". Multi-
# statement transactions work correctly as long as each propose reaches the
# same leader — which holds since the leader serialises execution via its
# internal mutex and writes are forwarded to it automatically.

class TrashPandaDB::RaftDriver < DB::Driver
  class Connection < DB::Connection
    def initialize(options : ::DB::Connection::Options, @uri : URI)
      super(options)
    end

    def build_prepared_statement(query) : ::DB::Statement
      Statement.new(self, query)
    end

    def build_unprepared_statement(query) : ::DB::Statement
      Statement.new(self, query)
    end

    def perform_begin_transaction
      _propose("BEGIN", [] of TrashPandaDB::SQL::Value)
    end

    def perform_commit_transaction
      _propose("COMMIT", [] of TrashPandaDB::SQL::Value)
    end

    def perform_rollback_transaction
      _propose("ROLLBACK", [] of TrashPandaDB::SQL::Value)
    end

    def perform_create_savepoint(name)
      _propose("SAVEPOINT #{name}", [] of TrashPandaDB::SQL::Value)
    end

    def perform_release_savepoint(name)
      _propose("RELEASE SAVEPOINT #{name}", [] of TrashPandaDB::SQL::Value)
    end

    def perform_rollback_savepoint(name)
      _propose("ROLLBACK TO SAVEPOINT #{name}", [] of TrashPandaDB::SQL::Value)
    end

    def do_close
    end

    def send_request(action : String, sql : String, args : Array(TrashPandaDB::SQL::Value)) : JSON::Any
      host = @uri.host || "localhost"
      port = @uri.port || 9002

      payload = JSON.build do |j|
        j.object do
          j.field "action", action
          j.field "sql", sql
          unless args.empty?
            j.field "params" do
              j.array { args.each { |v| encode_value(j, v) } }
            end
          end
        end
      end

      sock = TCPSocket.new(host, port, connect_timeout: 5.seconds)
      sock.read_timeout = 30.seconds
      sock.write_timeout = 5.seconds
      sock.puts(payload)
      raw = sock.gets || %({"ok":false,"error":"no response from Raft node"})
      sock.close
      JSON.parse(raw)
    rescue ex
      JSON.parse(%({"ok":false,"error":#{ex.message.to_json}}))
    ensure
      sock.try(&.close) rescue nil
    end

    private def _propose(sql : String, args : Array(TrashPandaDB::SQL::Value)) : Nil
      resp = send_request("propose", sql, args)
      raise ::DB::Error.new(resp["error"]?.try(&.as_s) || "Raft propose failed") unless resp["ok"]?.try(&.as_bool)
    end

    private def encode_value(j : JSON::Builder, v : TrashPandaDB::SQL::Value) : Nil
      case v
      when Nil     then j.null
      when Bool    then j.number(v ? 1_i64 : 0_i64)
      when Int64   then j.number(v)
      when Float64 then j.number(v)
      when String  then j.string(v)
      when Bytes   then j.string(v.hexstring)
      end
    end
  end

  class Statement < ::DB::Statement
    def initialize(connection : ::DB::Connection, command : String)
      super(connection, command)
    end

    protected def perform_query(args : Enumerable) : ::DB::ResultSet
      conn = @connection.as(Connection)
      sql_args = coerce_args(args)
      action = select_action(@command)
      resp = conn.send_request(action, @command, sql_args)
      unless resp["ok"]?.try(&.as_bool)
        raise ::DB::Error.new(resp["error"]?.try(&.as_s) || "Raft #{action} failed")
      end
      col_names = resp["cols"]?.try(&.as_a.map(&.as_s)) || [] of String
      rows = resp["rows"]?.try(&.as_a.map { |row|
        row.as_a.map { |v| json_to_value(v) }
      }) || [] of Array(TrashPandaDB::SQL::Value)
      TrashPandaDB::ResultSet.new(self, rows, col_names)
    end

    protected def perform_exec(args : Enumerable) : ::DB::ExecResult
      conn = @connection.as(Connection)
      sql_args = coerce_args(args)
      resp = conn.send_request("propose", @command, sql_args)
      unless resp["ok"]?.try(&.as_bool)
        raise ::DB::Error.new(resp["error"]?.try(&.as_s) || "Raft propose failed")
      end
      rows_affected = resp["rows_affected"]?.try(&.as_i64) || 0_i64
      last_id = resp["last_id"]?.try(&.as_i64) || 0_i64
      ::DB::ExecResult.new(rows_affected, last_id)
    end

    protected def do_close
    end

    private def select_action(sql : String) : String
      s = sql.strip.upcase
      (s.starts_with?("SELECT") || s.starts_with?("EXPLAIN") || s.starts_with?("PRAGMA")) ? "query" : "propose"
    end

    private def json_to_value(v : JSON::Any) : TrashPandaDB::SQL::Value
      case v.raw
      when Nil     then nil.as(TrashPandaDB::SQL::Value)
      when Bool    then (v.as_bool ? 1_i64 : 0_i64).as(TrashPandaDB::SQL::Value)
      when Int64   then v.as_i64.as(TrashPandaDB::SQL::Value)
      when Float64 then v.as_f.as(TrashPandaDB::SQL::Value)
      when String  then v.as_s.as(TrashPandaDB::SQL::Value)
      else              nil.as(TrashPandaDB::SQL::Value)
      end
    end

    private def coerce_args(args : Enumerable) : Array(TrashPandaDB::SQL::Value)
      result = Array(TrashPandaDB::SQL::Value).new
      args.each { |v| result << coerce_one(v) }
      result
    end

    private def coerce_one(v) : TrashPandaDB::SQL::Value
      case v
      when Nil     then nil
      when Bool    then v ? 1_i64 : 0_i64
      when Int64   then v
      when Int32   then v.to_i64
      when Int16   then v.to_i64
      when Int8    then v.to_i64
      when UInt64  then v.to_i64
      when UInt32  then v.to_i64
      when UInt16  then v.to_i64
      when UInt8   then v.to_i64
      when Float64 then v
      when Float32 then v.to_f64
      when String  then v
      when Bytes   then v
      when Time    then v.to_rfc3339
      else              nil
      end
    end
  end

  class ConnectionBuilder < ::DB::ConnectionBuilder
    def initialize(@options : ::DB::Connection::Options, @uri : URI)
    end

    def build : ::DB::Connection
      Connection.new(@options, @uri)
    end
  end

  def connection_builder(uri : URI) : ::DB::ConnectionBuilder
    params = HTTP::Params.parse(uri.query || "")
    ConnectionBuilder.new(connection_options(params), uri)
  end
end

DB.register_driver "trashpandaraft", TrashPandaDB::RaftDriver
