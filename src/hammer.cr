require "socket"
require "json"
require "option_parser"
require "file_utils"
require "random/secure"

# ── Config ────────────────────────────────────────────────────────────────────

node_count      = 3
writers         = 20
duration        = 30
image           = "trash-panda-raft"
build           = false
keep            = false
connect         = [] of String   # host:port pairs for an existing cluster
chaos_mode      = false
chaos_interval  = 5
chaos_recover   = 3
chaos_min_alive = -1  # -1 = auto (quorum)
persistent      = false
replication_key = nil.as(String?)

OptionParser.parse do |p|
  p.banner = "Usage: hammer [options]"
  p.on("--nodes N",            "Replicas to start via Podman (default: 3)")           { |v| node_count      = v.to_i }
  p.on("--writers M",          "Concurrent write fibers (default: 20)")                { |v| writers         = v.to_i }
  p.on("--duration D",         "Write phase in seconds (default: 30)")                 { |v| duration        = v.to_i }
  p.on("--image TAG",          "Podman image tag (default: trash-panda-raft)")         { |v| image           = v      }
  p.on("--build",              "Build binary + image before starting")                 { build = true                 }
  p.on("--keep",               "Leave containers running after test")                  { keep  = true                 }
  p.on("--connect ADDR",       "host:port[,host:port] — skip Podman")                 { |v| connect         = v.split(",") }
  p.on("--chaos",              "Enable chaos monkey (kill/restart random nodes)")      { chaos_mode = true            }
  p.on("--chaos-interval S",   "Seconds between kills (default: 5)")                  { |v| chaos_interval  = v.to_i }
  p.on("--chaos-recover S",    "Seconds before restarting a killed node (default: 3)") { |v| chaos_recover   = v.to_i }
  p.on("--chaos-min-alive N",  "Minimum live nodes (default: quorum = nodes/2+1)")    { |v| chaos_min_alive = v.to_i }
  p.on("--persistent",         "Use --data-dir with host volumes (survive restarts)") { persistent = true             }
  p.on("--encrypt",            "Auto-generate a key and encrypt Raft RPC traffic")    { replication_key = Random::Secure.random_bytes(32).hexstring }
  p.on("--key HEX",            "Hex-encoded 32-byte key for Raft RPC encryption")     { |v| replication_key = v      }
  p.on("--help",               "Show this help")                                       { puts p; exit                 }
end

# ── Constants ─────────────────────────────────────────────────────────────────

RAFT_PORT   = 9001
CLIENT_PORT = 9002

# ── RPC ───────────────────────────────────────────────────────────────────────

def rpc(host : String, port : Int32, action : String, sql : String? = nil) : JSON::Any
  TCPSocket.open(host, port) do |sock|
    sock.read_timeout = 10.seconds
    req = JSON.build { |j| j.object { j.field "action", action; j.field "sql", sql if sql } }
    sock.puts req
    JSON.parse(sock.gets.not_nil!)
  end
rescue ex
  JSON.parse(%({"ok":false,"error":#{ex.message.to_json}}))
end

def rpc_addr(addr : String, action : String, sql : String? = nil) : JSON::Any
  host, port = addr.split(":")
  rpc(host, port.to_i, action, sql)
end

# ── Cluster helpers ───────────────────────────────────────────────────────────

def find_free_port : Int32
  s = TCPServer.new("127.0.0.1", 0)
  p = s.local_address.port
  s.close
  p
end

def wait_for_leader(addrs : Array(String), timeout : Time::Span = 15.seconds) : String?
  deadline = Time.instant + timeout
  while Time.instant < deadline
    addrs.each do |addr|
      r = rpc_addr(addr, "status")
      return addr if r["role"]?.try(&.as_s) == "Leader"
    rescue
    end
    sleep 200.milliseconds
  end
  nil
end

def node_label(addrs : Array(String), addr : String) : String
  idx = addrs.index(addr).try { |i| i + 1 } || "?"
  "n#{idx}(#{addr})"
end

# ── Podman cluster startup ────────────────────────────────────────────────────

suffix   = "hammer-#{Process.pid}"
net_name = "raft-#{suffix}"
cnames   = (1..node_count).map { |i| "raft-n#{i}-#{suffix}" }
hports   = Array(Int32).new(node_count) { find_free_port }
addrs    = hports.map { |p| "127.0.0.1:#{p}" }

using_podman = connect.empty?
data_dirs    = Array(String?).new(node_count) { nil }

if using_podman
  if build
    puts "► Building binary..."
    abort "Build failed" unless system("crystal build src/trashpandadb.cr -o bin/trashpandadb 2>&1")
    puts "► Building image #{image}..."
    abort "Image build failed" unless system("podman build -t #{image} -f Containerfile . > /dev/null 2>&1")
  end

  at_exit do
    unless keep
      print "\nTearing down cluster... "
      cnames.each { |n| system("podman rm -f #{n} > /dev/null 2>&1") }
      system("podman network rm -f #{net_name} > /dev/null 2>&1")
      data_dirs.each { |d| FileUtils.rm_rf(d) if d }
      puts "done."
    end
  end

  puts "► Starting #{node_count}-node cluster (image: #{image})"
  if k = replication_key
    puts "  encryption: ChaCha20-Poly1305  key=#{k[0, 16]}..."
  end
  system("podman network create #{net_name} > /dev/null 2>&1")

  peer_specs        = (1..node_count).map { |i| "n#{i}=raft-n#{i}-#{suffix}:#{RAFT_PORT}" }
  client_peer_specs = (1..node_count).map { |i| "n#{i}=raft-n#{i}-#{suffix}:#{CLIENT_PORT}" }
  cnames.each_with_index do |cname, i|
    node_id          = "n#{i + 1}"
    my_peers         = peer_specs.reject { |s| s.starts_with?("#{node_id}=") }
    my_client_peers  = client_peer_specs.reject { |s| s.starts_with?("#{node_id}=") }
    peer_args        = my_peers.map { |s| "--peer #{s}" }.join(" ")
    client_peer_args = my_client_peers.map { |s| "--client-peer #{s}" }.join(" ")
    volume_args = ""
    env_args    = ""
    extra_args  = ""
    if persistent
      data_dir = "/tmp/raft-data-#{suffix}-n#{i + 1}"
      Dir.mkdir_p(data_dir)
      data_dirs[i] = data_dir
      volume_args = "-v #{data_dir}:/data"
      extra_args  = "--data-dir /data"
    end
    env_args = "-e TPDB_REPLICATION_KEY=#{replication_key}" if replication_key
    cmd = "podman run -d --name #{cname} --hostname #{cname} " \
          "--network #{net_name} -p #{hports[i]}:#{CLIENT_PORT} " \
          "#{volume_args} #{env_args} #{image} --node-id #{node_id} " \
          "--raft 0.0.0.0:#{RAFT_PORT} --client 0.0.0.0:#{CLIENT_PORT} " \
          "#{peer_args} #{client_peer_args} #{extra_args}"
    abort "Failed to start #{cname}" unless system("#{cmd} > /dev/null 2>&1")
    puts "  #{node_id}  →  127.0.0.1:#{hports[i]}"
  end
else
  addrs = connect
  puts "► Connecting to existing cluster: #{addrs.join(", ")}"
end

# ── Leader election ───────────────────────────────────────────────────────────

print "► Waiting for leader"
leader_addr = wait_for_leader(addrs)
abort "\n  No leader elected within 15s — aborting." unless leader_addr
puts "  →  leader: #{node_label(addrs, leader_addr)}"

# ── Schema ────────────────────────────────────────────────────────────────────

r = rpc_addr(leader_addr, "propose",
  "CREATE TABLE hammer (id TEXT PRIMARY KEY, writer INTEGER NOT NULL, seq INTEGER NOT NULL, port INTEGER NOT NULL)")
abort "Schema creation failed: #{r["error"]?}" unless r["ok"]?.try(&.as_bool)

# ── Hammer ────────────────────────────────────────────────────────────────────

puts ""
puts "► Hammering  writers=#{writers}  duration=#{duration}s  nodes=#{addrs.size}"
puts "  (writes spread round-robin across all nodes — followers forward to leader)"
puts ""

written        = Atomic(Int64).new(0_i64)
failed         = Atomic(Int64).new(0_i64)
stop_flag      = Atomic(Int32).new(0)
done_ch        = Channel(Nil).new(writers)
chaos_kills    = Atomic(Int32).new(0)
chaos_restarts = Atomic(Int32).new(0)
successful_ids = [] of String
ids_mutex      = Mutex.new

t_start = Time.instant

writers.times do |w|
  spawn do
    seq = 0
    until stop_flag.get != 0
      addr = addrs[(w + seq) % addrs.size]
      host, port = addr.split(":")
      sql = "INSERT INTO hammer (id, writer, seq, port) VALUES ('#{w}_#{seq}', #{w}, #{seq}, #{port})"
      if rpc(host, port.to_i, "propose", sql)["ok"]?.try(&.as_bool)
        written.add(1)
        ids_mutex.synchronize { successful_ids << "#{w}_#{seq}" }
      else
        failed.add(1)
      end
      seq += 1
    end
    done_ch.send(nil)
  end
end

# Progress ticker
spawn do
  until stop_flag.get != 0
    elapsed = (Time.instant - t_start).total_seconds
    w = written.get
    f = failed.get
    rate = elapsed > 0 ? (w / elapsed) : 0.0
    STDERR.print "\r  %4.0fs  written: %6d  failed: %4d  rate: %5.0f writes/s" %
      {elapsed, w, f, rate}
    sleep 500.milliseconds
  end
end

# ── Chaos monkey ──────────────────────────────────────────────────────────────

dead_nodes = [] of String
dead_mutex = Mutex.new

if chaos_mode && using_podman
  min_alive = (chaos_min_alive < 0 ? (node_count / 2 + 1) : chaos_min_alive).to_i
  puts "► Chaos monkey enabled  interval=#{chaos_interval}s  recover=#{chaos_recover}s  min_alive=#{min_alive}"
  puts ""

  spawn do
    sleep chaos_interval.seconds
    until stop_flag.get != 0
      victim = nil
      dead_mutex.synchronize do
        alive = cnames.reject { |n| dead_nodes.includes?(n) }
        if alive.size > min_alive
          victim = alive.sample
          dead_nodes << victim.not_nil!
        end
      end

      if v = victim
        label = node_label(addrs, addrs[cnames.index(v).not_nil!])
        STDERR.print "\n  [chaos] killing #{label}... "
        system("podman kill #{v} > /dev/null 2>&1")
        chaos_kills.add(1)
        STDERR.print "killed. restarting in #{chaos_recover}s\n"
        sleep chaos_recover.seconds
        break if stop_flag.get != 0  # don't restart after write phase ends
        STDERR.print "  [chaos] restarting #{label}... "
        system("podman start #{v} > /dev/null 2>&1")
        chaos_restarts.add(1)
        STDERR.print "up.\n"
        dead_mutex.synchronize { dead_nodes.delete(v) }
      end

      sleep chaos_interval.seconds
    end
  end
end

sleep duration.seconds
stop_flag.set(1)
writers.times { done_ch.receive }

# Restart any nodes that were killed but not yet restarted
if chaos_mode && using_podman
  dead_mutex.synchronize do
    unless dead_nodes.empty?
      STDERR.puts ""
      dead_nodes.each do |cname|
        label = node_label(addrs, addrs[cnames.index(cname).not_nil!])
        STDERR.print "  [chaos] restarting #{label} before verify... "
        system("podman start #{cname} > /dev/null 2>&1")
        chaos_restarts.add(1)
        STDERR.print "up.\n"
      end
      dead_nodes.clear
    end
  end
end

elapsed   = (Time.instant - t_start).total_seconds
n_written = written.get
n_failed  = failed.get

STDERR.print "\r" + " " * 70 + "\r"  # clear progress line

puts "─" * 56
puts "  Write phase complete"
puts "  Duration   : #{elapsed.round(1)}s"
puts "  Written    : #{n_written}"
puts "  Failed     : #{n_failed}"
puts "  Throughput : #{(n_written / elapsed).round(0).to_i} writes/s"
if chaos_mode
  puts "  Kills      : #{chaos_kills.get}"
  puts "  Restarts   : #{chaos_restarts.get}"
end
puts "─" * 56

# ── Verification ─────────────────────────────────────────────────────────────

# Poll until every node responds and all agree on a stable count for two
# consecutive polls. The "stable" requirement ensures that apply fibers have
# finished draining any pending commits, not just that they've reached the
# same in-progress snapshot.
settle_timeout = chaos_mode ? 120 : 10
print "\n► Waiting for all nodes to converge (timeout #{settle_timeout}s)..."
converged   = false
settle_took = 0
prev_stable : Array(Int64?) = [] of Int64?
settle_timeout.times do |i|
  sleep 1.second
  counts = addrs.map do |addr|
    r = rpc_addr(addr, "local_query", "SELECT COUNT(*) FROM hammer")
    r["ok"]?.try(&.as_bool) ? r["rows"].as_a.first.as_a.first.raw.as(Int64) : nil
  rescue
    nil
  end
  if counts.all?(&.itself) && counts.uniq.size == 1
    if counts == prev_stable
      converged   = true
      settle_took = i + 1
      break
    end
    prev_stable = counts
  else
    prev_stable = [] of Int64?
  end
end
puts converged ? " converged in #{settle_took}s" : " timed out after #{settle_timeout}s"
puts ""
puts "► Verifying #{addrs.size} nodes:"

counts    = {} of String => Int64
nodes_ok  = true

addrs.each do |addr|
  r = rpc_addr(addr, "local_query", "SELECT COUNT(*) FROM hammer")
  label = node_label(addrs, addr)
  if r["ok"]?.try(&.as_bool)
    count = r["rows"].as_a.first.as_a.first.raw.as(Int64)
    counts[addr] = count
    puts "  #{label.ljust(24)} #{count.to_s.rjust(7)} rows"
  else
    puts "  #{label.ljust(24)} ERROR — #{r["error"]?}"
    nodes_ok = false
  end
end

puts ""

puts ""

# Diagnostic: fetch commit_index, last_applied, heartbeat for each node
puts "► Diagnostics (ci / la / li / bi / sni / snap / hb):"
addrs.each do |addr|
  r = rpc_addr(addr, "status")
  label = node_label(addrs, addr)
  if r["ok"]?.try(&.as_bool)
    ci   = r["commit_index"]
    la   = r["last_applied"]
    ll   = r["log_last_index"]
    bi   = r["log_base_index"]
    sni  = r["snapshot_last_index"]
    snap = r["has_snapshot_file"]
    hb   = r["heartbeat_ms"]
    role = r["role"]?.try(&.as_s) || "?"
    ci_s   = ci.try(&.to_s)   || "?"
    la_s   = la.try(&.to_s)   || "?"
    ll_s   = ll.try(&.to_s)   || "?"
    bi_s   = bi.try(&.to_s)   || "?"
    sni_s  = sni.try(&.to_s)  || "?"
    snap_s = snap.try(&.to_s) || "?"
    hb_s   = hb.try(&.to_s)   || "?"
    suffix = role == "Leader" ? "  [LEADER]" : ""
    puts "  #{label.ljust(24)} ci=#{ci_s.ljust(7)} la=#{la_s.ljust(7)} li=#{ll_s.ljust(7)} bi=#{bi_s.ljust(7)} sni=#{sni_s.ljust(7)} snap=#{snap_s.ljust(5)} hb=#{hb_s}ms#{suffix}"
    if role == "Leader" && (peers = r["peers"]?)
      peers.as_h.each do |pid, info|
        nx = info["next"]
        mc = info["match"]
        puts "    #{pid.ljust(6)} next=#{nx} match=#{mc}"
      end
    end
  else
    puts "  #{label.ljust(24)} ERROR — #{r["error"]?}"
  end
end
puts ""

unique_counts = counts.values.uniq
if unique_counts.size > 1
  nodes_ok = false
  puts "✗  Nodes disagree on row count: #{counts.map { |a, c| "#{node_label(addrs, a)}=#{c}" }.join(", ")}"
  puts "   Fetching full ID lists to diff..."
  id_sets = {} of String => Array(String)
  addrs.each do |addr|
    r = rpc_addr(addr, "local_query", "SELECT id FROM hammer ORDER BY id")
    if r["ok"]?.try(&.as_bool)
      id_sets[addr] = r["rows"].as_a.map { |row| row.as_a.first.as_s }
    end
  end
  ref_addr, ref_ids = id_sets.first
  id_sets.each do |addr, ids|
    next if addr == ref_addr
    missing = ref_ids - ids
    extra   = ids - ref_ids
    label   = node_label(addrs, addr)
    puts "  #{label} vs #{node_label(addrs, ref_addr)}: missing=#{missing.size} extra=#{extra.size}"
    puts "    first missing: #{missing.first(5).join(", ")}" unless missing.empty?
  end
else
  got = unique_counts.first
  # In chaos mode, some writes that returned network errors may have been committed
  # before the node was killed — so got >= n_written is expected and correct.
  # Any count in [n_written, n_written + n_failed] is acceptable.
  if got < n_written
    nodes_ok = false
    puts "✗  All nodes agree (#{got} rows) but expected at least #{n_written}."
    puts "   #{n_written - got} committed rows are missing."
    # Fetch actual IDs from the first available node and diff against expected
    ref_addr = addrs.find { |a| counts[a]? == got }
    if ref_addr
      r = rpc_addr(ref_addr, "local_query", "SELECT id FROM hammer ORDER BY id")
      if r["ok"]?.try(&.as_bool)
        actual_ids = r["rows"].as_a.map { |row| row.as_a.first.as_s }.to_set
        expected_ids = successful_ids.to_set
        missing = expected_ids - actual_ids
        extra   = actual_ids - expected_ids
        puts "   Missing IDs: #{missing.size}"
        unless missing.empty?
          # Show first 20 missing IDs and cluster info
          sorted = missing.to_a.sort
          puts "   First 20 missing: #{sorted.first(20).join(", ")}"
          # Check if missing are from specific writers (nodes)
          writer_counts = Hash(Int32, Int32).new(0)
          missing.each do |id|
            w = id.split('_').first.to_i
            writer_counts[w] = writer_counts[w] + 1
          end
          puts "   Missing by writer: #{writer_counts.to_a.sort.map { |w, c| "w#{w}=#{c}" }.join(", ")}"
        end
        puts "   Extra (unexpected) IDs: #{extra.size}" unless extra.empty?
      end
    end
  elsif got > n_written + n_failed
    nodes_ok = false
    puts "✗  All nodes agree (#{got} rows) but that exceeds all #{n_written + n_failed} attempted writes."
  elsif got == n_written
    puts "✓  All #{addrs.size} nodes consistent: #{n_written} rows confirmed on every node."
  else
    extra = got - n_written
    puts "✓  All #{addrs.size} nodes consistent: #{got} rows on every node (#{n_written} reported ok + #{extra} committed-but-unacked due to chaos)."
  end
end

exit(nodes_ok ? 0 : 1)
