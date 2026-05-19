require "../spec_helper"
require "socket"
require "json"

# Podman integration test for Raft replication.
#
# Spins up 3 containers in a private Podman network, verifies writes
# to the leader propagate to all nodes, and confirms the cluster
# re-elects after the leader is killed.
#
# Skipped automatically when `podman` is not in PATH.

private RAFT_IMAGE    = "trash-panda-raft-test"
private RAFT_PORT     = 9001  # inter-node RPC (internal)
private CLIENT_PORT   = 9002  # JSON client API (published)

# ── Helpers ───────────────────────────────────────────────────────────────────

private def podman_available? : Bool
  system("podman version > /dev/null 2>&1")
end

private def find_free_port : Int32
  s = TCPServer.new("127.0.0.1", 0)
  p = s.local_address.port
  s.close
  p
end

# Send one JSON request to the client port; return parsed response.
private def rpc(host : String, port : Int32, action : String, sql : String? = nil) : JSON::Any
  sock = TCPSocket.new(host, port, connect_timeout: 2.seconds)
  sock.read_timeout = 5.seconds
  req = JSON.build do |j|
    j.object do
      j.field "action", action
      j.field "sql", sql if sql
    end
  end
  sock.puts(req)
  reply = sock.gets.not_nil!
  sock.close
  JSON.parse(reply)
rescue ex
  JSON.parse(%({"ok":false,"error":"#{ex.message}"}))
end

# Poll until the node at +port+ reports it is Leader (or timeout).
private def wait_leader(port : Int32, timeout_ms : Int32 = 8000) : Bool
  deadline = Time.instant + timeout_ms.milliseconds
  while Time.instant < deadline
    begin
      r = rpc("127.0.0.1", port, "status")
      return true if r["role"]?.try(&.as_s) == "Leader"
    rescue
    end
    sleep 200.milliseconds
  end
  false
end

# Find which of the given ports is the leader; return it.
private def find_leader_port(ports : Array(Int32), timeout_ms : Int32 = 8000) : Int32?
  deadline = Time.instant + timeout_ms.milliseconds
  while Time.instant < deadline
    ports.each do |p|
      begin
        r = rpc("127.0.0.1", p, "status")
        return p if r["role"]?.try(&.as_s) == "Leader"
      rescue
      end
    end
    sleep 200.milliseconds
  end
  nil
end

# ── Spec ──────────────────────────────────────────────────────────────────────

describe "Podman 3-node Raft cluster" do
  pending "podman not available" unless podman_available?

  suffix     = Process.pid.to_s
  net_name   = "raft-net-#{suffix}"
  image_tag  = "#{RAFT_IMAGE}-#{suffix}"
  # Container names  (unique per test run)
  cnames     = (1..3).map { |i| "raft-n#{i}-#{suffix}" }
  # Host-side client ports (random)
  hports     = Array(Int32).new(3) { find_free_port }

  after_all do
    cnames.each { |n| system("podman rm -f #{n} > /dev/null 2>&1") }
    system("podman rmi -f #{image_tag} > /dev/null 2>&1")
    system("podman network rm -f #{net_name} > /dev/null 2>&1")
  end

  it "builds the container image" do
    crystal_build = system(
      "crystal build src/trashpandadb.cr -o bin/trashpandadb 2>&1"
    )
    crystal_build.should be_true

    image_build = system(
      "podman build -t #{image_tag} -f Containerfile . > /dev/null 2>&1"
    )
    image_build.should be_true
  end

  it "starts a 3-node cluster and elects a leader" do
    # Create isolated network
    system("podman network create #{net_name} > /dev/null 2>&1").should be_true

    peer_specs = (1..3).map { |i| "n#{i}=raft-n#{i}-#{suffix}:#{RAFT_PORT}" }

    cnames.each_with_index do |cname, i|
      node_id   = "n#{i + 1}"
      my_peers  = peer_specs.reject { |s| s.starts_with?("#{node_id}=") }
      peer_args = my_peers.map { |s| "--peer #{s}" }.join(" ")

      cmd = [
        "podman run -d",
        "--name #{cname}",
        "--hostname #{cname}",
        "--network #{net_name}",
        "-p #{hports[i]}:#{CLIENT_PORT}",
        image_tag,
        "--node-id #{node_id}",
        "--raft 0.0.0.0:#{RAFT_PORT}",
        "--client 0.0.0.0:#{CLIENT_PORT}",
        peer_args,
      ].join(" ")

      system("#{cmd} > /dev/null 2>&1").should be_true
    end

    # Wait for any node to become leader (up to 8s)
    leader_port = find_leader_port(hports, 8000)
    leader_port.should_not be_nil
  end

  it "replicates writes to all nodes" do
    leader_port = find_leader_port(hports, 5000).not_nil!

    r = rpc("127.0.0.1", leader_port, "propose",
      "CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)")
    r["ok"].as_bool.should be_true

    r = rpc("127.0.0.1", leader_port, "propose",
      "INSERT INTO kv VALUES ('ping', 'pong')")
    r["ok"].as_bool.should be_true

    # Give followers time to apply the committed entries
    sleep 400.milliseconds

    # All nodes should have the row (local_query bypasses leader check)
    hports.each do |port|
      result = rpc("127.0.0.1", port, "local_query",
        "SELECT v FROM kv WHERE k = 'ping'")
      result["ok"].as_bool.should be_true
      result["rows"].as_a.first.as_a.first.as_s.should eq("pong")
    end
  end

  it "re-elects after the leader is killed" do
    leader_port = find_leader_port(hports, 5000)
    leader_port.should_not be_nil

    # Find the container name for the current leader
    leader_status = rpc("127.0.0.1", leader_port.not_nil!, "status")
    leader_node_id = leader_status["node_id"].as_s  # e.g. "n2"
    leader_idx = leader_node_id.lstrip("n").to_i - 1
    leader_cname = cnames[leader_idx]

    # Kill the leader container immediately (no graceful shutdown wait)
    system("podman kill #{leader_cname} > /dev/null 2>&1")

    remaining_ports = hports.each_with_index.reject { |_, i| i == leader_idx }.map(&.first).to_a

    # A new leader should emerge among the survivors (allow 12s for re-election)
    new_leader_port = find_leader_port(remaining_ports, 12000)
    new_leader_port.should_not be_nil

    # The new leader must be different from the old one
    new_status = rpc("127.0.0.1", new_leader_port.not_nil!, "status")
    new_status["node_id"].as_s.should_not eq(leader_node_id)
  end

  it "accepts writes after re-election" do
    # Find the surviving (responsive) ports by polling status
    remaining_ports = hports.select do |p|
      begin
        rpc("127.0.0.1", p, "status")["ok"]?.try(&.as_bool) == true
      rescue
        false
      end
    end

    new_leader_result = find_leader_port(remaining_ports, 15000)
    new_leader_result.should_not be_nil
    new_leader_port = new_leader_result.not_nil!

    r = rpc("127.0.0.1", new_leader_port, "propose",
      "INSERT INTO kv VALUES ('after_re_election', 'yes')")
    r["ok"].as_bool.should be_true

    sleep 400.milliseconds

    # Both surviving nodes should have the new row (local_query)
    remaining_ports.each do |port|
      result = rpc("127.0.0.1", port, "local_query",
        "SELECT v FROM kv WHERE k = 'after_re_election'")
      result["ok"].as_bool.should be_true
      result["rows"].as_a.first.as_a.first.as_s.should eq("yes")
    end
  end
end
