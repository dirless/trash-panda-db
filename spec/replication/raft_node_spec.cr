require "../spec_helper"
require "../../src/trash_panda_db/replication/raft_node"

include TrashPandaDB::Replication

# Spin up a 3-node in-process cluster on localhost with auto-assigned ports.
private def find_free_port : Int32
  s = TCPServer.new("127.0.0.1", 0)
  port = s.local_address.port
  s.close
  port
end

private struct NodeSetup
  getter node : RaftNode
  getter db : TrashPandaDB::SQL::Database
  getter port : Int32

  def initialize(@node, @db, @port); end
end

private def build_cluster(count : Int32, data_dirs : Array(String?), cipher : Cipher? = nil) : Array(NodeSetup)
  ports = Array(Int32).new(count) { find_free_port }
  peer_specs = (0...count).map { |i| "n#{i + 1}=127.0.0.1:#{ports[i]}" }

  (0...count).map do |i|
    db = if dd = data_dirs[i]
      Dir.mkdir_p(dd)
      TrashPandaDB::SQL::Database.new(TrashPandaDB::Storage::Pager.new(File.join(dd, "data.db")))
    else
      TrashPandaDB::SQL::Database.new
    end
    peers = peer_specs.reject { |s| s.starts_with?("n#{i + 1}=") }
    node = RaftNode.new(
      node_id: "n#{i + 1}",
      listen_addr: "127.0.0.1:#{ports[i]}",
      peers: peers,
      sql_db: db,
      data_dir: data_dirs[i],
      cipher: cipher
    )
    NodeSetup.new(node, db, ports[i])
  end
end

private def wait_for_leader(nodes : Array(NodeSetup), timeout_ms : Int32 = 3000) : NodeSetup?
  deadline = Time.instant + timeout_ms.milliseconds
  while Time.instant < deadline
    leader = nodes.find { |n| n.node.role == Role::Leader }
    return leader if leader
    sleep 50.milliseconds
  end
  nil
end

# Helper: wait until a node reaches a given role.
private def wait_role(node : RaftNode, role : Role, timeout_ms : Int32 = 2000) : Bool
  deadline = Time.instant + timeout_ms.milliseconds
  while Time.instant < deadline
    return true if node.role == role
    sleep 30.milliseconds
  end
  false
end

describe RaftNode do
  describe "single node (no peers)" do
    it "immediately becomes leader with no peers" do
      db   = TrashPandaDB::SQL::Database.new
      node = RaftNode.new("n1", "127.0.0.1:#{find_free_port}", [] of String, sql_db: db)
      node.start
      wait_role(node, Role::Leader, 800).should be_true
      node.stop
    end

    it "can propose a write and query the result" do
      db   = TrashPandaDB::SQL::Database.new
      node = RaftNode.new("n1", "127.0.0.1:#{find_free_port}", [] of String, sql_db: db)
      node.start
      wait_role(node, Role::Leader, 800).should be_true

      node.propose("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      node.propose("INSERT INTO items VALUES (1, 'trash panda')")

      result = node.query("SELECT name FROM items WHERE id = 1")
      result.rows.first.first.should eq("trash panda")

      node.stop
    end
  end

  describe "error handling" do
    it "propose raises DB::Error when not leader" do
      db   = TrashPandaDB::SQL::Database.new
      node = RaftNode.new("n1", "127.0.0.1:#{find_free_port}", [] of String, sql_db: db)
      # Don't start — stays Follower

      expect_raises(DB::Error, /not the leader/) do
        node.propose("CREATE TABLE t (id INTEGER)")
      end
    end

    it "query raises DB::Error when not leader" do
      db   = TrashPandaDB::SQL::Database.new
      node = RaftNode.new("n1", "127.0.0.1:#{find_free_port}", [] of String, sql_db: db)

      expect_raises(DB::Error, /not the leader/) do
        node.query("SELECT 1")
      end
    end
  end

  describe "inline_args value coercion" do
    it "inlines all SQL::Value types into SQL text" do
      db   = TrashPandaDB::SQL::Database.new
      node = RaftNode.new("n1", "127.0.0.1:#{find_free_port}", [] of String, sql_db: db)
      node.start
      wait_role(node, Role::Leader, 600)

      node.propose("CREATE TABLE vals (id INTEGER, v TEXT)")

      # Integer
      node.propose("INSERT INTO vals VALUES (?, ?)", [1_i64, "hello"] of TrashPandaDB::SQL::Value)
      # Float
      node.propose("INSERT INTO vals VALUES (2, ?)", [3.14_f64] of TrashPandaDB::SQL::Value)
      # NULL
      node.propose("INSERT INTO vals VALUES (3, ?)", [nil] of TrashPandaDB::SQL::Value)
      # Bool coerced to 1/0
      node.propose("INSERT INTO vals VALUES (4, ?)", [true] of TrashPandaDB::SQL::Value)
      # String with embedded single-quote
      node.propose("INSERT INTO vals VALUES (5, ?)", ["it's alive"] of TrashPandaDB::SQL::Value)

      r = node.query("SELECT id, v FROM vals ORDER BY id")
      r.rows.size.should eq(5)
      r.rows[0][1].should eq("hello")
      r.rows[1][1].to_s.should start_with("3.14")
      r.rows[2][1].should be_nil
      r.rows[3][1].should eq(1_i64)
      r.rows[4][1].should eq("it's alive")

      node.stop
    end
  end

  describe "multiple sequential proposals" do
    it "commits all proposals in order" do
      db   = TrashPandaDB::SQL::Database.new
      node = RaftNode.new("n1", "127.0.0.1:#{find_free_port}", [] of String, sql_db: db)
      node.start
      wait_role(node, Role::Leader, 600)

      node.propose("CREATE TABLE counter (n INTEGER)")
      10.times { |i| node.propose("INSERT INTO counter VALUES (#{i})") }

      r = node.query("SELECT COUNT(*) FROM counter")
      r.rows.first.first.should eq(10_i64)

      node.stop
    end
  end

  describe "3-node cluster" do
    tmp_dirs = ["/tmp/raft_n1_#{Process.pid}", "/tmp/raft_n2_#{Process.pid}", "/tmp/raft_n3_#{Process.pid}"]

    after_each do
      tmp_dirs.each { |d| system("rm -rf #{d}") rescue nil }
    end

    it "elects exactly one leader" do
      setups = build_cluster(3, [nil, nil, nil])
      setups.each { |s| s.node.start }

      leader_setup = wait_for_leader(setups, 3000)
      leader_setup.should_not be_nil

      leaders = setups.count { |s| s.node.role == Role::Leader }
      leaders.should eq(1)

      setups.each { |s| s.node.stop }
    end

    it "replicates a write to all nodes" do
      setups = build_cluster(3, [nil, nil, nil])
      setups.each { |s| s.node.start }

      leader_setup = wait_for_leader(setups, 3000)
      leader_setup.should_not be_nil
      leader = leader_setup.not_nil!.node

      leader.propose("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)")
      leader.propose("INSERT INTO kv VALUES ('hello', 'world')")

      # Give followers time to apply
      sleep 200.milliseconds

      setups.each do |s|
        result = s.db.execute("SELECT v FROM kv WHERE k = 'hello'", [] of TrashPandaDB::SQL::Value)
        rows = result.as(TrashPandaDB::SQL::QueryResult).rows
        rows.first.first.should eq("world")
      end

      setups.each { |s| s.node.stop }
    end

    it "leader steps down when it receives a higher-term RequestVote" do
      setups = build_cluster(3, [nil, nil, nil])
      setups.each { |s| s.node.start }

      leader_setup = wait_for_leader(setups, 3000)
      leader_setup.should_not be_nil
      leader = leader_setup.not_nil!.node
      leader_port = leader_setup.not_nil!.port

      old_term = leader.current_term

      # Send a RequestVote with a higher term directly to the leader's TCP port.
      high_term = old_term + 10
      msg = RequestVote.new(high_term, "fake-candidate", 0_i64, 0_i64).to_wire
      sock = TCPSocket.new("127.0.0.1", leader_port, connect_timeout: 1.second)
      sock.puts(msg)
      sock.gets  # read reply (we don't care about its content)
      sock.close

      # Leader should have stepped down to Follower with updated term.
      sleep 100.milliseconds
      leader.role.should eq(Role::Follower)
      leader.current_term.should eq(high_term)

      setups.each { |s| s.node.stop }
    end

    it "slow follower catches up after lag" do
      setups = build_cluster(3, [nil, nil, nil])
      setups.each { |s| s.node.start }

      leader_setup = wait_for_leader(setups, 3000)
      leader_setup.should_not be_nil
      leader = leader_setup.not_nil!.node

      # Identify a follower and stop it.
      laggard = setups.find { |s| s.node.role != Role::Leader }.not_nil!
      laggard.node.stop

      # Write while laggard is offline (majority = leader + other follower).
      leader.propose("CREATE TABLE catchup (n INTEGER)")
      5.times { |i| leader.propose("INSERT INTO catchup VALUES (#{i})") }
      sleep 200.milliseconds

      # Restart the laggard — it should catch up via AppendEntries.
      ports = setups.map(&.port)
      peer_specs = (0...3).map { |i| "n#{i + 1}=127.0.0.1:#{ports[i]}" }
      laggard_i = setups.index(laggard).not_nil!
      new_db   = TrashPandaDB::SQL::Database.new
      new_node = RaftNode.new(
        node_id:     "n#{laggard_i + 1}",
        listen_addr: "127.0.0.1:#{laggard.port}",
        peers:       peer_specs.reject { |s| s.starts_with?("n#{laggard_i + 1}=") },
        sql_db:      new_db
      )
      new_node.start
      sleep 600.milliseconds  # wait for heartbeats to replicate all entries

      r = new_db.execute("SELECT COUNT(*) FROM catchup", [] of TrashPandaDB::SQL::Value)
      count = r.as(TrashPandaDB::SQL::QueryResult).rows.first.first
      count.should eq(5_i64)

      setups.each { |s| s.node.stop rescue nil }
      new_node.stop
    end

    it "persists state and recovers after restart" do
      dirs = tmp_dirs
      setups = build_cluster(3, dirs)
      setups.each { |s| s.node.start }

      leader_setup = wait_for_leader(setups, 3000)
      leader_setup.should_not be_nil
      leader = leader_setup.not_nil!.node

      leader.propose("CREATE TABLE persist_test (id INTEGER PRIMARY KEY, val TEXT)")
      leader.propose("INSERT INTO persist_test VALUES (1, 'survived')")

      sleep 200.milliseconds
      setups.each { |s| s.node.stop }

      # Rebuild cluster from same data dirs
      ports = setups.map(&.port)
      peer_specs = (0...3).map { |i| "n#{i + 1}=127.0.0.1:#{ports[i]}" }

      setups2 = (0...3).map do |i|
        db = TrashPandaDB::SQL::Database.new(TrashPandaDB::Storage::Pager.new(File.join(dirs[i], "data.db")))
        peers = peer_specs.reject { |s| s.starts_with?("n#{i + 1}=") }
        node = RaftNode.new(
          node_id: "n#{i + 1}",
          listen_addr: "127.0.0.1:#{ports[i]}",
          peers: peers,
          sql_db: db,
          data_dir: dirs[i]
        )
        NodeSetup.new(node, db, ports[i])
      end

      setups2.each { |s| s.node.start }
      wait_for_leader(setups2, 3000).should_not be_nil

      # Reapply committed log entries to the new DBs via the new leader
      leader2 = setups2.find { |s| s.node.role == Role::Leader }.not_nil!.node
      sleep 300.milliseconds

      setups2.each do |s|
        result = s.db.execute("SELECT val FROM persist_test WHERE id = 1", [] of TrashPandaDB::SQL::Value)
        rows = result.as(TrashPandaDB::SQL::QueryResult).rows
        rows.first.first.should eq("survived")
      end

      setups2.each { |s| s.node.stop }
    end
  end

  describe "cluster membership changes" do
    it "propose_add_node raises when not leader" do
      db   = TrashPandaDB::SQL::Database.new
      node = RaftNode.new("n1", "127.0.0.1:#{find_free_port}", [] of String, sql_db: db)
      expect_raises(DB::Error, /not the leader/) do
        node.propose_add_node("n2", "127.0.0.1:9999", "127.0.0.1:9998")
      end
    end

    it "propose_add_node raises for a node already in the cluster" do
      db   = TrashPandaDB::SQL::Database.new
      port = find_free_port
      node = RaftNode.new("n1", "127.0.0.1:#{port}", [] of String, sql_db: db)
      node.start
      wait_role(node, Role::Leader, 800).should be_true
      expect_raises(DB::Error, /already a cluster member/) do
        node.propose_add_node("n1", "127.0.0.1:#{port}", "127.0.0.1:9998")
      end
      node.stop
    end

    it "adds a new node to a single-node cluster" do
      # Start n1 as a single-node leader.
      db1    = TrashPandaDB::SQL::Database.new
      port1  = find_free_port
      node1  = RaftNode.new("n1", "127.0.0.1:#{port1}", [] of String, sql_db: db1)
      node1.start
      wait_role(node1, Role::Leader, 1000).should be_true

      node1.propose("CREATE TABLE t (id INTEGER)")
      node1.propose("INSERT INTO t VALUES (1)")

      # Start n2 with n1 as a peer (joining mode suppresses elections).
      db2   = TrashPandaDB::SQL::Database.new
      port2 = find_free_port
      node2 = RaftNode.new(
        node_id:     "n2",
        listen_addr: "127.0.0.1:#{port2}",
        peers:       ["n1=127.0.0.1:#{port1}"],
        sql_db:      db2,
        joining:     true
      )
      node2.start

      # Leader admits n2.
      node1.propose_add_node("n2", "127.0.0.1:#{port2}", "127.0.0.1:9998")

      # n2 is now a full member — allow it to participate in elections.
      node2.finish_joining

      # Give n2 time to catch up via heartbeats.
      sleep 300.milliseconds

      result = db2.execute("SELECT id FROM t", [] of TrashPandaDB::SQL::Value)
      rows = result.as(TrashPandaDB::SQL::QueryResult).rows
      rows.first.first.should eq(1_i64)

      node1.members.has_key?("n2").should be_true

      node1.stop
      node2.stop
    end
  end

  describe "encrypted cluster (ChaCha20-Poly1305)" do
    it "proposes and queries across all nodes with a shared key" do
      key = Random::Secure.random_bytes(Cipher::KEY_SIZE)
      cipher = Cipher.new(key)
      nodes = build_cluster(3, [nil, nil, nil], cipher)
      nodes.each(&.node.start)

      leader_setup = wait_for_leader(nodes)
      leader_setup.should_not be_nil
      leader = leader_setup.not_nil!.node

      leader.propose("CREATE TABLE enc_test (id INTEGER PRIMARY KEY, val TEXT)")
      leader.propose("INSERT INTO enc_test VALUES (1, 'hello')")
      leader.propose("INSERT INTO enc_test VALUES (2, 'world')")

      sleep 150.milliseconds

      result = leader.query("SELECT val FROM enc_test ORDER BY id")
      result.rows.size.should eq 2
      result.rows[0][0].should eq "hello"
      result.rows[1][0].should eq "world"

      # All followers should have converged.
      nodes.each do |ns|
        r = ns.db.execute("SELECT COUNT(*) FROM enc_test", [] of TrashPandaDB::SQL::Value)
        r.as(TrashPandaDB::SQL::QueryResult).rows.first.first.should eq 2_i64
      end

      nodes.each(&.node.stop)
    end
  end
end
