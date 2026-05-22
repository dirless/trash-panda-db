require "json"
require "option_parser"
require "socket"
require "./trash_panda_db"
require "./trash_panda_db/storage/pager"
require "./trash_panda_db/replication"

# Standalone Raft node server.
#
# Each connection to the client port handles one JSON request and closes.
#
# Peer discovery — two mutually exclusive modes:
#   Explicit:  --peer n1=host:9001  --client-peer n1=host:9002  (repeat per peer)
#   DNS:       --dns-peers db.example.com  [--dns-raft-port 9001]  [--dns-client-port 9002]
#              Resolves all A records; each IP becomes a peer. Own IP is auto-excluded.
#
# Request types:
#   {"action":"status"}
#   {"action":"metrics"}
#   {"action":"propose","sql":"..."}   — forwarded to leader if received by a follower
#   {"action":"query","sql":"..."}
#   {"action":"local_query","sql":"..."}
#
# Responses:
#   {"ok":true,"role":"Leader","node_id":"...","leader_id":"...","term":N}
#   {"ok":true,"rows_affected":N,"last_id":N}
#   {"ok":true,"cols":[...],"rows":[[...],...]}
#   {"ok":false,"error":"..."}

module RaftNodeServer
  def self.value_to_json(v : TrashPandaDB::SQL::Value) : JSON::Any
    case v
    when Nil     then JSON::Any.new(nil)
    when Bool    then JSON::Any.new(v)
    when Int64   then JSON::Any.new(v)
    when Float64 then JSON::Any.new(v)
    when String  then JSON::Any.new(v)
    when Bytes   then JSON::Any.new(v.hexstring)
    else              JSON::Any.new(nil)
    end
  end

  # Raises if any explicit --peer ID matches the node's own node_id.
  # Exposed for testing.
  def self.validate_explicit_peers!(node_id : String, peers : Array(String)) : Nil
    self_peers = peers.select { |p| p.split("=", 2).first == node_id }
    unless self_peers.empty?
      raise ArgumentError.new(
        "--peer includes this node's own ID '#{node_id}': #{self_peers.join(", ")}. Remove it."
      )
    end
  end

  # Pure peer-config builder — no DNS, no I/O, raises on bad input.
  # Exposed at module level so specs can exercise it directly.
  def self.build_peer_config(
    ips : Array(String),
    own_ip : String?,
    raft_port : Int32,
    client_port : Int32,
    min_cluster_size : Int32
  ) : {Array(String), Hash(String, String), String?}
    if ips.empty?
      raise ArgumentError.new("peer IP list is empty")
    end

    if ips.size < min_cluster_size
      raise ArgumentError.new(
        "--dns-minimum-cluster-size is #{min_cluster_size} but resolved to " \
        "only #{ips.size} address#{ips.size == 1 ? "" : "es"} (#{ips.join(", ")}). " \
        "Update the DNS record or lower --dns-minimum-cluster-size."
      )
    end

    peer_ips   = own_ip ? ips.reject { |ip| ip == own_ip } : ips
    raft_specs = peer_ips.map { |ip| "#{ip}=#{ip}:#{raft_port}" }
    client_map = peer_ips.each_with_object(Hash(String, String).new) do |ip, h|
      h[ip] = "#{ip}:#{client_port}"
    end

    {raft_specs, client_map, own_ip}
  end

  # Resolve a DNS hostname to all A-record IPs, then delegate to build_peer_config.
  # Prints progress to STDERR and calls exit on failure.
  private def self.resolve_dns_peers(
    hostname : String,
    raft_host : String,
    raft_port : Int32,
    client_port : Int32,
    min_cluster_size : Int32
  ) : {Array(String), Hash(String, String), String?}
    addrs = Socket::Addrinfo.resolve(hostname, raft_port.to_s,
      type: Socket::Type::STREAM, protocol: Socket::Protocol::TCP)
    ips = addrs.map(&.ip_address.address).uniq

    STDERR.puts "DNS #{hostname} → #{ips.join(", ")} (#{ips.size} address#{ips.size == 1 ? "" : "es"})"

    own_ip = if raft_host == "0.0.0.0" || raft_host == "::"
      my_addrs = Socket::Addrinfo.resolve(
        System.hostname, "0",
        type: Socket::Type::STREAM, protocol: Socket::Protocol::TCP
      ) rescue [] of Socket::Addrinfo
      my_ips = my_addrs.map(&.ip_address.address)
      ips.find { |ip| my_ips.includes?(ip) }
    else
      ips.find { |ip| ip == raft_host }
    end

    STDERR.puts "Own IP: #{own_ip || "(not detected — treating all resolved IPs as peers)"}"

    build_peer_config(ips, own_ip, raft_port, client_port, min_cluster_size)
  rescue ex : ArgumentError
    STDERR.puts "ERROR: #{ex.message}"
    exit 1
  end

  # Proxy a raw wire line to another node's client port; return the raw reply.
  private def self.forward_to(addr : String, wire : String) : String
    host, port = addr.split(":", 2)
    fwd = TCPSocket.new(host, port.to_i, connect_timeout: 2.seconds)
    fwd.read_timeout  = 10.seconds
    fwd.write_timeout = 2.seconds
    fwd.puts(wire)
    reply = fwd.gets || %({"ok":false,"error":"no reply from leader"})
    fwd.close
    reply
  rescue ex
    %({"ok":false,"error":"forward failed: #{ex.message}"})
  end

  def self.handle_client(sock : TCPSocket, node : TrashPandaDB::Replication::RaftNode,
                         db : TrashPandaDB::SQL::Database)
    sock.read_timeout = 5.seconds
    line = sock.gets
    unless line
      sock.close
      return
    end

    response = begin
      req    = JSON.parse(line.strip)
      action = req["action"]?.try(&.as_s) || "unknown"

      case action
      when "status"
        hb_age = (Time.instant - node.last_heartbeat).total_milliseconds.to_i64
        JSON.build do |j|
          j.object do
            j.field "ok",               true
            j.field "role",             node.role.to_s
            j.field "node_id",          node.node_id
            j.field "leader_id",        node.leader_id || ""
            j.field "term",             node.current_term
            j.field "commit_index",     node.commit_index
            j.field "last_applied",     node.last_applied
            j.field "log_last_index",   node.log_last_index
            j.field "heartbeat_ms",     hb_age
            # Only the leader has meaningful peer replication state
            j.field "peers" do
              j.object do
                node.peer_replication.each do |id, info|
                  j.field id do
                    j.object do
                      j.field "next",  info[:next]
                      j.field "match", info[:match]
                    end
                  end
                end
              end
            end
            j.field "members" do
              j.object do
                node.members.each do |id, addrs|
                  j.field id do
                    j.object do
                      j.field "raft",   addrs[:raft]
                      j.field "client", addrs[:client]
                    end
                  end
                end
              end
            end
          end
        end

      when "join"
        # A new node requests admission. node_id, raft_addr, client_addr are required.
        new_id          = req["node_id"].as_s
        new_raft_addr   = req["raft_addr"].as_s
        new_client_addr = req["client_addr"].as_s
        begin
          node.propose_add_node(new_id, new_raft_addr, new_client_addr)
          JSON.build { |j| j.object { j.field "ok", true } }
        rescue ex : DB::Error
          # Not the leader — forward to leader.
          leader = node.leader_id
          if leader && (leader_addr = node.client_addr_for(leader))
            forward_to(leader_addr, line.strip)
          else
            JSON.build { |j| j.object { j.field "ok", false; j.field "error", ex.message || "not leader" } }
          end
        end

      when "propose"
        sql = req["sql"].as_s
        begin
          result = node.propose(sql)
          case result
          when TrashPandaDB::SQL::ExecResult
            JSON.build do |j|
              j.object do
                j.field "ok",           true
                j.field "rows_affected", result.rows_affected
                j.field "last_id",       result.last_insert_id
              end
            end
          else
            JSON.build { |j| j.object { j.field "ok", true; j.field "rows_affected", 0; j.field "last_id", 0 } }
          end
        rescue ex : DB::Error
          # Not the leader — proxy to leader if its client address is known.
          leader = node.leader_id
          if leader && (leader_addr = node.client_addr_for(leader))
            forward_to(leader_addr, line.strip)
          else
            JSON.build { |j| j.object { j.field "ok", false; j.field "error", ex.message || "db error" } }
          end
        end

      when "query"
        sql    = req["sql"].as_s
        result = node.query(sql)
        rows_json = result.rows.map { |row| row.map { |v| value_to_json(v) } }
        JSON.build do |j|
          j.object do
            j.field "ok",   true
            j.field "cols", result.col_names
            j.field "rows", rows_json
          end
        end

      when "local_query"
        sql = req["sql"].as_s
        raw = db.execute(sql, [] of TrashPandaDB::SQL::Value)
        qr  = raw.as(TrashPandaDB::SQL::QueryResult)
        rows_json = qr.rows.map { |row| row.map { |v| value_to_json(v) } }
        JSON.build do |j|
          j.object do
            j.field "ok",   true
            j.field "cols", qr.col_names
            j.field "rows", rows_json
          end
        end

      when "metrics"
        JSON.build do |j|
          j.object do
            j.field "queries_total",      db.queries_total
            j.field "writes_total",       db.writes_total
            j.field "slow_queries_total", db.slow_queries_total
            j.field "commit_index",       node.commit_index
            j.field "last_applied",       node.last_applied
            j.field "role",               node.role.to_s
            j.field "term",               node.current_term
            j.field "peers" do
              j.object do
                node.peer_replication.each do |id, info|
                  j.field id do
                    j.object { j.field "match", info[:match] }
                  end
                end
              end
            end
          end
        end

      else
        JSON.build { |j| j.object { j.field "ok", false; j.field "error", "unknown action: #{action}" } }
      end
    rescue ex : DB::Error
      JSON.build { |j| j.object { j.field "ok", false; j.field "error", ex.message || "db error" } }
    rescue ex
      JSON.build { |j| j.object { j.field "ok", false; j.field "error", ex.message || "error" } }
    end

    sock.puts(response)
  rescue
  ensure
    sock.close rescue nil
  end

  def self.run(argv : Array(String))
    node_id         = ""
    raft_addr       = "0.0.0.0:9001"
    client_addr     = "0.0.0.0:9002"
    peers           = [] of String
    client_peers    = Hash(String, String).new
    data_dir        = nil.as(String?)
    dns_peers_host  = nil.as(String?)
    dns_raft_port   = 9001
    dns_client_port = 9002
    dns_min_cluster_size = 3
    join_addr       = nil.as(String?)

    OptionParser.parse(argv) do |opts|
      opts.banner = "Usage: trashpandadb --node-id ID --raft HOST:PORT --client HOST:PORT " \
                    "[--peer ID=HOST:PORT]... [--client-peer ID=HOST:PORT]... " \
                    "[--dns-peers HOSTNAME [--dns-raft-port PORT] [--dns-client-port PORT]] " \
                    "[--join HOST:PORT] [--data-dir DIR]"
      opts.on("--node-id ID",          "Node identifier")                                    { |v| node_id    = v }
      opts.on("--raft ADDR",           "Raft RPC listen address (default 0.0.0.0:9001)")     { |v| raft_addr  = v }
      opts.on("--client ADDR",         "Client API listen address (default 0.0.0.0:9002)")   { |v| client_addr = v }
      opts.on("--peer SPEC",           "Explicit Raft peer: ID=HOST:PORT (repeatable)")       { |v| peers << v }
      opts.on("--client-peer SPEC",    "Explicit client peer: ID=HOST:PORT (repeatable)") do |v|
        id, addr = v.split("=", 2)
        client_peers[id] = addr
      end
      opts.on("--dns-peers HOSTNAME",  "DNS hostname whose A records are the peer IPs")      { |v| dns_peers_host  = v }
      opts.on("--dns-raft-port PORT",  "Raft port for DNS-discovered peers (default 9001)")  { |v| dns_raft_port   = v.to_i }
      opts.on("--dns-client-port PORT","Client port for DNS-discovered peers (default 9002)") { |v| dns_client_port = v.to_i }
      opts.on("--dns-minimum-cluster-size N",
              "Minimum node count required from DNS (default 3); refuses to start if the " \
              "A record resolves to fewer IPs")                                               { |v| dns_min_cluster_size = v.to_i }
      opts.on("--join ADDR",           "Join an existing cluster via its client API address") { |v| join_addr = v }
      opts.on("--data-dir DIR",        "Persistent data directory")                           { |v| data_dir = v }
      opts.on("-h", "--help",          "Show help")                                           { puts opts; exit }
    end

    # DNS peer discovery — resolve once at startup.
    if dns_host = dns_peers_host
      raft_host = raft_addr.split(":").first
      dns_peers, dns_client_map, own_ip = resolve_dns_peers(
        dns_host, raft_host, dns_raft_port, dns_client_port, dns_min_cluster_size
      )
      peers.concat(dns_peers)
      dns_client_map.each { |k, v| client_peers[k] = v }
      # Auto-assign node_id from detected own IP if not explicitly set.
      node_id = own_ip if node_id.empty? && own_ip
    end

    if node_id.empty?
      STDERR.puts "ERROR: --node-id is required (or use --dns-peers so it can be auto-detected)"
      exit 1
    end

    # Detect self-peer: a node listing itself in --peer causes split-vote thrashing.
    begin
      validate_explicit_peers!(node_id, peers)
    rescue ex : ArgumentError
      STDERR.puts "ERROR: #{ex.message}"
      exit 1
    end

    joining = !join_addr.nil?
    STDERR.puts "[#{node_id}] raft=#{raft_addr} client=#{client_addr} peers=#{peers} " \
                "join=#{join_addr || "none"} data=#{data_dir || "memory"}"

    Dir.mkdir_p(data_dir.not_nil!) if data_dir
    db = if d = data_dir
      TrashPandaDB::SQL::Database.new(
        TrashPandaDB::Storage::Pager.new(File.join(d, "data.db"))
      )
    else
      TrashPandaDB::SQL::Database.new
    end
    node = TrashPandaDB::Replication::RaftNode.new(
      node_id:     node_id,
      listen_addr: raft_addr,
      peers:       peers,
      client_peers: client_peers,
      sql_db:      db,
      data_dir:    data_dir,
      joining:     joining
    )
    node.start

    # Client API server
    chost, cport = client_addr.split(":", 2)
    client_server = TCPServer.new(chost, cport.to_i)

    spawn do
      loop do
        sock = client_server.accept? || break
        spawn handle_client(sock, node, db)
      end
    end

    # If --join was given, send a join request to the existing cluster and wait
    # for it to be committed before enabling elections on this node.
    if addr = join_addr
      spawn do
        join_payload = JSON.build do |j|
          j.object do
            j.field "action",      "join"
            j.field "node_id",     node_id
            j.field "raft_addr",   raft_addr
            j.field "client_addr", client_addr
          end
        end

        loop do
          begin
            reply_raw = forward_to(addr, join_payload)
            reply     = JSON.parse(reply_raw)
            if reply["ok"]?.try(&.as_bool)
              STDERR.puts "[#{node_id}] joined cluster successfully"
              node.finish_joining
              break
            else
              err = reply["error"]?.try(&.as_s) || "unknown error"
              if err.includes?("retry in a moment") || err.includes?("not leader")
                STDERR.puts "[#{node_id}] join pending (#{err}), retrying…"
                sleep 1.second
              else
                STDERR.puts "[#{node_id}] join failed: #{err}"
                sleep 2.seconds
              end
            end
          rescue join_ex
            STDERR.puts "[#{node_id}] join error: #{join_ex.message}, retrying…"
            sleep 2.seconds
          end
        end
      end
    end

    STDERR.puts "[#{node_id}] ready"

    Signal::TERM.trap { node.stop; client_server.close; exit 0 }
    Signal::INT.trap  { node.stop; client_server.close; exit 0 }

    sleep
  end
end

RaftNodeServer.run(ARGV) unless ENV["CRYSTAL_SPEC_CONTEXT"]?
