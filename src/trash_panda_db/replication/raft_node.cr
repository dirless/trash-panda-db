require "json"
require "socket"
require "base64"
require "./log_entry"
require "./raft_log"
require "./messages"
require "./cipher"

module TrashPandaDB::Replication
  private ELECTION_TIMEOUT_MIN  = 150
  private ELECTION_TIMEOUT_MAX  = 600
  private HEARTBEAT_INTERVAL    =  50
  private MAX_ENTRIES_PER_RPC   = 200
  private SNAPSHOT_CHUNK_SIZE   = 256 * 1024

  # After a node takes a snapshot at index N, the Raft log is truncated to N
  # and all subsequent restarts load state from the snapshot file.  Entries
  # committed BEFORE the first snapshot (indices 1 … SNAPSHOT_INTERVAL-1)
  # are vulnerable: if every node in a quorum loses both its Raft log and its
  # data directory simultaneously (disk failure, volume wipe), those entries
  # are unrecoverable.
  #
  # Smaller values shrink the vulnerable window at the cost of more frequent
  # disk I/O during the snapshot (flush + checkpoint + file copy).
  # 256 is a good trade-off for development and small production clusters;
  # raise it (e.g. 2048) on high-throughput clusters where snapshot overhead
  # becomes significant.
  private SNAPSHOT_INTERVAL = 256

  enum Role
    Follower
    Candidate
    Leader
  end

  # Persistent state — saved atomically on every mutation.
  private struct PersistentState
    include JSON::Serializable

    property current_term : Int64
    property voted_for : String?
    property commit_index : Int64
    property last_applied : Int64

    def initialize(@current_term = 0_i64, @voted_for = nil, @commit_index = 0_i64, @last_applied = 0_i64); end
  end

  # Snapshot metadata — written alongside the snapshot DB file.
  struct SnapshotMetadata
    include JSON::Serializable

    getter last_included_index : Int64
    getter last_included_term : Int64

    def initialize(@last_included_index : Int64, @last_included_term : Int64); end
  end

  class RaftNode
    getter node_id : String
    getter role : Role
    getter current_term : Int64
    getter leader_id : String?
    getter commit_index : Int64
    getter last_applied : Int64
    getter last_heartbeat : Time::Instant

    @peers : Hash(String, String)         # node_id => raft_addr
    @client_peers : Hash(String, String)  # node_id => client_addr
    @cipher : Cipher?
    @last_heartbeat : Time::Instant
    @election_start_not_before : Time::Instant
    @tcp_server : TCPServer?
    @pending_config_change : Bool
    @joining : Bool
    @snapshot_last_index : Int64
    @snapshot_path : String?
    # Follower in-progress chunked snapshot transfer state (protected by @mu).
    @xfer_index : Int64
    @xfer_offset : Int64
    # Set of peer IDs that currently have a replicate_to fiber in flight.
    @replicating    : Set(String)
    @replicating_mu : Mutex

    # peers:        Array of "node_id=host:raft_port"
    # client_peers: Hash of node_id => "host:client_port" (for write forwarding)
    # joining:      When true, suppress elections until finish_joining is called.
    def initialize(
      @node_id : String,
      @listen_addr : String,
      peers : Array(String),
      client_peers : Hash(String, String) = Hash(String, String).new,
      @sql_db : SQL::Database = SQL::Database.new,
      data_dir : String? = nil,
      joining : Bool = false,
      cipher : Cipher? = nil
    )
      @cipher = if c = cipher
        c
      elsif key = ENV["TPDB_REPLICATION_KEY"]?
        Cipher.from_hex(key)
      end
      @peers = parse_peers(peers)
      @client_peers = client_peers.dup
      @data_dir = data_dir
      @role = Role::Follower
      @current_term = 0_i64
      @voted_for = nil
      @leader_id = nil
      @joining = joining
      @pending_config_change = false

      @log = RaftLog.new(data_dir)
      @commit_index = 0_i64
      @last_applied = 0_i64

      @next_index  = Hash(String, Int64).new
      @match_index = Hash(String, Int64).new

      @pending    = Hash(Int64, Tuple(Int64, Channel(SQL::ExecuteResult | Exception))).new
      @pending_mu = Mutex.new

      @pending_config    = Hash(Int64, Channel(Exception?)).new
      @pending_config_mu = Mutex.new

      @last_heartbeat = Time.instant
      # If we start with peers, give a 1-second grace before holding elections.
      # This lets the leader's heartbeats reach us before our timer fires, so a
      # freshly restarted node with an empty log can't force the leader to step
      # down. With no peers we're bootstrapping a fresh cluster — no delay needed.
      @election_start_not_before = peers.empty? ? Time.instant : Time.instant + 1.second
      @tcp_server = nil

      @mu = Mutex.new
      @stop_channel  = Channel(Nil).new
      @apply_channel = Channel(Nil).new(64)

      @state_path = data_dir ? File.join(data_dir.not_nil!, "raft_state.json") : nil
      @snapshot_path = data_dir ? File.join(data_dir.not_nil!, "raft_snapshot.db") : nil
      @snapshot_last_index = 0_i64
      @xfer_index = 0_i64
      @xfer_offset = 0_i64
      @replicating    = Set(String).new
      @replicating_mu = Mutex.new
      load_persistent_state
      snapshot_applied = apply_snapshot_if_present
      unless snapshot_applied
        # Recreate pager from scratch regardless of log truncation.
        # When the pager has stale state from a crash, replay_committed
        # re-applies entries whose keys may already exist — the btree
        # does NOT enforce key uniqueness at the storage layer, and
        # bt.search() can miss stale entries, allowing duplicate rows.
        # Recreating the pager and replaying from base_index guarantees
        # clean state and no duplicates.
        @sql_db.recreate_pager!
        @last_applied = @log.base_index
        @commit_index = {@commit_index, @log.last_index}.min
      end
      replay_committed
    end

    # ── Public API ────────────────────────────────────────────────────────────

    def log_last_index : Int64
      @log.last_index
    end

    # Returns peer replication state: peer_id => {next_index, match_index}.
    def peer_replication : Hash(String, NamedTuple(next: Int64, match: Int64))
      result = Hash(String, NamedTuple(next: Int64, match: Int64)).new
      @mu.synchronize do
        @peers.each_key do |id|
          result[id] = {
            next:  @next_index[id]? || 0_i64,
            match: @match_index[id]? || 0_i64,
          }
        end
      end
      result
    end

    def start : Nil
      spawn_server
      spawn_apply_loop
      spawn_election_timeout
    end

    def stop : Nil
      @stop_channel.close rescue nil
      @tcp_server.try &.close rescue nil
      @log.close
      err = DB::Error.new("node stopped")
      @pending_mu.synchronize do
        @pending.each_value { |_, ch| ch.send(err) rescue nil }
        @pending.clear
      end
      @pending_config_mu.synchronize do
        @pending_config.each_value { |ch| ch.send(err) rescue nil }
        @pending_config.clear
      end
    end

    # Submit a write command. Blocks until committed (or raises if not leader).
    def propose(sql : String, args : Array(SQL::Value) = [] of SQL::Value) : SQL::ExecuteResult
      inlined = inline_args(sql, args)
      reply_ch = Channel(SQL::ExecuteResult | Exception).new(1)
      @mu.synchronize do
        raise DB::Error.new("not the leader (leader=#{@leader_id})") unless @role == Role::Leader
        entry = @log.append(@current_term, inlined)
        @pending_mu.synchronize { @pending[entry.index] = {entry.term, reply_ch} }
      end

      replicate_to_all

      result = reply_ch.receive
      raise result if result.is_a?(Exception)
      result.as(SQL::ExecuteResult)
    end

    # Request that a new node be added to the cluster. Blocks until committed.
    # Raises if not leader, already a member, or a config change is in progress.
    def propose_add_node(new_node_id : String, new_raft_addr : String, new_client_addr : String) : Nil
      reply_ch = Channel(Exception?).new(1)

      @mu.synchronize do
        raise DB::Error.new("not the leader (leader=#{@leader_id})") unless @role == Role::Leader
        if new_node_id == @node_id || @peers.has_key?(new_node_id)
          raise DB::Error.new("'#{new_node_id}' is already a cluster member")
        end
        raise DB::Error.new("membership change in progress, retry in a moment") if @pending_config_change

        @pending_config_change = true

        # Add the new peer immediately so replication starts before the entry commits.
        # The joining node's raft port must already be listening.
        @peers[new_node_id] = new_raft_addr
        @client_peers[new_node_id] = new_client_addr
        @next_index[new_node_id]  = 1_i64
        @match_index[new_node_id] = 0_i64

        entry = @log.append_add_node(@current_term, new_node_id, new_raft_addr, new_client_addr)
        @pending_config_mu.synchronize { @pending_config[entry.index] = reply_ch }
      end

      replicate_to_all

      if ex = reply_ch.receive
        raise ex
      end
    end

    # Called after a successful join to re-enable elections.
    def finish_joining : Nil
      @mu.synchronize { @joining = false }
    end

    # Execute a linearisable read (Raft §8 read-index protocol).
    #
    # Steps:
    #  1. Record read_index = commit_index under @mu.
    #  2. Send an empty AppendEntries heartbeat to all peers and wait for a
    #     majority ack (confirms we still hold the leadership lease).
    #     Single-node clusters skip this step.
    #  3. Wait for last_applied >= read_index.
    #  4. Execute the query.
    def query(sql : String, args : Array(SQL::Value) = [] of SQL::Value) : SQL::QueryResult
      read_index, term, single_node = @mu.synchronize do
        raise DB::Error.new("not the leader (leader=#{@leader_id})") unless @role == Role::Leader
        {@commit_index, @current_term, @peers.empty?}
      end

      unless single_node
        raise DB::Error.new("not the leader: could not confirm quorum") unless send_read_heartbeat(term)
        @mu.synchronize do
          raise DB::Error.new("not the leader (leader=#{@leader_id})") unless @role == Role::Leader && @current_term == term
        end
      end

      raise DB::Error.new("read-index wait timed out") unless wait_applied(read_index)

      result = @sql_db.execute(sql, args)
      result.as(SQL::QueryResult)
    end

    # Returns the client address for write forwarding, or nil if unknown.
    def client_addr_for(id : String) : String?
      @client_peers[id]?
    end

    # Returns current cluster members: node_id => {raft, client}.
    def members : Hash(String, NamedTuple(raft: String, client: String))
      result = Hash(String, NamedTuple(raft: String, client: String)).new
      @mu.synchronize do
        @peers.each do |id, raft|
          result[id] = {raft: raft, client: @client_peers[id]? || ""}
        end
      end
      result
    end

    # ── TCP server ────────────────────────────────────────────────────────────

    private def spawn_server
      host, port = split_addr(@listen_addr)
      server = TCPServer.new(host, port.to_i)
      @tcp_server = server
      spawn do
        loop do
          begin
            sock = server.accept?
            break unless sock
            spawn handle_connection(sock)
          rescue
            break
          end
        end
      end
    end

    private def handle_connection(sock : TCPSocket)
      sock.read_timeout = 2.seconds
      line = sock.gets
      return unless line
      begin
        decrypted = decrypt_wire(line.strip)
        return unless decrypted
        msg = Replication.parse_message(decrypted)
        reply_wire = case msg
                     when RequestVote     then handle_request_vote(msg).to_wire
                     when PreVoteRequest  then handle_pre_vote_request(msg).to_wire
                     when AppendEntries   then handle_append_entries(msg).to_wire
                     when InstallSnapshot then handle_install_snapshot(msg).to_wire
                     end
        sock.puts(encrypt_wire(reply_wire)) if reply_wire
      rescue
      ensure
        sock.close
      end
    end

    # ── Election timeout fiber ────────────────────────────────────────────────

    private def spawn_election_timeout
      spawn do
        loop do
          begin
            select
            when @stop_channel.receive
              break
            when timeout(rand_election_timeout)
              timed_out = false
              @mu.synchronize do
                next if @role == Role::Leader || @joining
                next if Time.instant < @election_start_not_before
                elapsed = (Time.instant - @last_heartbeat).total_milliseconds
                timed_out = elapsed >= ELECTION_TIMEOUT_MIN
              end
              start_election if timed_out
            end
          rescue Channel::ClosedError
            break
          end
        end
      end
    end

    private def rand_election_timeout : Time::Span
      ms = ELECTION_TIMEOUT_MIN + rand(ELECTION_TIMEOUT_MAX - ELECTION_TIMEOUT_MIN)
      ms.milliseconds
    end

    # ── Leader heartbeat fiber ─────────────────────────────────────────────────

    private def spawn_heartbeat_loop
      spawn do
        loop do
          begin
            select
            when @stop_channel.receive
              break
            when timeout(HEARTBEAT_INTERVAL.milliseconds)
              break unless @role == Role::Leader
              replicate_to_all
            end
          rescue Channel::ClosedError
            break
          end
        end
      end
    end

    # ── Election ──────────────────────────────────────────────────────────────

    private def start_election
      # Pre-vote phase: confirm we can win before incrementing term and disrupting
      # the cluster. If we don't get pre-votes from a majority, stay follower.
      return unless request_pre_votes

      @mu.synchronize do
        @role = Role::Candidate
        @current_term += 1
        @voted_for = @node_id
        @last_heartbeat = Time.instant
        save_persistent_state

        if @peers.empty?
          become_leader_locked
          return
        end
      end

      term, last_idx, last_term = @mu.synchronize { {@current_term, @log.last_index, @log.last_term} }

      votes  = Atomic(Int32).new(1)
      needed = (@peers.size + 1) // 2 + 1

      @peers.each do |_peer_id, addr|
        spawn do
          msg   = RequestVote.new(term, @node_id, last_idx, last_term)
          reply = send_rpc(addr, msg.to_wire)
          next unless reply
          begin
            rv = RequestVoteReply.from_json(reply)
            @mu.synchronize do
              if rv.term > @current_term
                step_down_locked(rv.term)
              elsif rv.vote_granted && @role == Role::Candidate && @current_term == term
                new_count = votes.add(1) + 1
                become_leader_locked if new_count >= needed
              end
            end
          rescue
          end
        end
      end
    end

    private def become_leader_locked
      return if @role == Role::Leader
      @role = Role::Leader
      @leader_id = @node_id
      @peers.each_key do |peer_id|
        @next_index[peer_id]  = @log.last_index + 1
        @match_index[peer_id] = 0_i64
      end
      @log.append(@current_term, "") unless @peers.empty?
      if @peers.empty? && @log.last_index > @commit_index
        @commit_index = @log.last_index
        save_persistent_state
        notify_apply
      end
      spawn_heartbeat_loop
      spawn { replicate_to_all }
    end

    private def step_down_locked(new_term : Int64)
      @current_term = new_term
      @voted_for = nil
      @role = Role::Follower
      @leader_id = nil  # cleared so forwarding doesn't attempt to route to self
      @last_heartbeat = Time.instant
      save_persistent_state
    end

    # ── Pre-vote ─────────────────────────────────────────────────────────────

    private def request_pre_votes : Bool
      return true if @peers.empty?

      term, last_idx, last_term = @mu.synchronize { {@current_term, @log.last_index, @log.last_term} }
      needed    = (@peers.size + 1) // 2 + 1

      votes = Atomic(Int32).new(1)  # self-vote
      done  = Channel(Nil).new

      @peers.each do |_peer_id, addr|
        spawn do
          msg   = PreVoteRequest.new(term, @node_id, last_idx, last_term)
          reply = send_rpc(addr, msg.to_wire)
          if reply
            begin
              pv = PreVoteReply.from_json(reply)
              if pv.term > term
                @mu.synchronize { step_down_locked(pv.term) if pv.term > @current_term }
              elsif pv.vote_granted
                votes.add(1)
              end
            rescue
            end
          end
          done.send(nil)
        end
      end

      @peers.size.times { done.receive }
      votes.get >= needed
    end

    # ── RPC handlers ──────────────────────────────────────────────────────────

    private def handle_request_vote(msg : RequestVote) : RequestVoteReply
      @mu.synchronize do
        step_down_locked(msg.term) if msg.term > @current_term

        grant = false
        if msg.term >= @current_term
          can_vote = @voted_for.nil? || @voted_for == msg.candidate_id
          log_ok   = msg.last_log_term > @log.last_term ||
                     (msg.last_log_term == @log.last_term && msg.last_log_index >= @log.last_index)
          if can_vote && log_ok
            @voted_for = msg.candidate_id
            @last_heartbeat = Time.instant
            save_persistent_state
            grant = true
          end
        end

        RequestVoteReply.new(@current_term, grant)
      end
    end

    private def handle_pre_vote_request(msg : PreVoteRequest) : PreVoteReply
      # Same log up-to-date check as handle_request_vote, but NO state mutation.
      # Pre-votes are advisory — the peer does not update term, voted_for, or
      # reset its election timer. This prevents stale candidates (e.g. restarted
      # chaos nodes with empty logs) from disrupting the cluster.
      # @mu is held to get a consistent snapshot of current_term and log state
      # (consistent with every other RPC handler).
      @mu.synchronize do
        return PreVoteReply.new(@current_term, false) if msg.term < @current_term

        grant = msg.last_log_term > @log.last_term ||
                (msg.last_log_term == @log.last_term && msg.last_log_index >= @log.last_index)
        PreVoteReply.new(@current_term, grant)
      end
    end

    private def handle_append_entries(msg : AppendEntries) : AppendEntriesReply
      @mu.synchronize do
        step_down_locked(msg.term) if msg.term > @current_term

        if msg.term < @current_term
          return AppendEntriesReply.new(@current_term, false, @log.last_index)
        end

        @last_heartbeat = Time.instant
        @role = Role::Follower
        @leader_id = msg.leader_id

        unless @log.append_entries(msg.prev_log_index, msg.prev_log_term, msg.entries)
          return AppendEntriesReply.new(@current_term, false, @log.last_index)
        end

        if msg.leader_commit > @commit_index
          @commit_index = {msg.leader_commit, @log.last_index}.min
          save_persistent_state
          notify_apply
        end

        AppendEntriesReply.new(@current_term, true, @log.last_index)
      end
    end

    # ── Replication ───────────────────────────────────────────────────────────

    private def replicate_to_all
      return unless @role == Role::Leader
      @peers.each_key do |peer_id|
        already_running = @replicating_mu.synchronize do
          next true if @replicating.includes?(peer_id)
          @replicating.add(peer_id)
          false
        end
        next if already_running
        spawn do
          replicate_to(peer_id)
        ensure
          @replicating_mu.synchronize { @replicating.delete(peer_id) }
        end
      end
      if @peers.empty?
        @mu.synchronize do
          if @log.last_index > @commit_index
            @commit_index = @log.last_index
            save_persistent_state
            notify_apply
          end
        end
      end
    end

    private def replicate_to(peer_id : String)
      addr = @peers[peer_id]? || return

      # Check if follower needs a snapshot (its next_index is at or behind
      # the snapshot boundary). If so, send InstallSnapshot instead.
      needs_snapshot = @mu.synchronize do
        ni = @next_index[peer_id]? || @log.last_index + 1
        ni <= @log.base_index && @snapshot_last_index > 0
      end
      if needs_snapshot
        send_install_snapshot(peer_id)
        return
      end

      next_idx, prev_term, entries, term, commit = @mu.synchronize do
        ni = @next_index[peer_id]? || @log.last_index + 1
        pt = @log.term_at(ni - 1)
        en = @log.entries_from(ni - 1, MAX_ENTRIES_PER_RPC)
        {ni, pt, en, @current_term, @commit_index}
      end

      msg = AppendEntries.new(term, @node_id, next_idx - 1, prev_term, entries, commit)
      raw = send_rpc(addr, msg.to_wire)
      return unless raw

      begin
        reply = AppendEntriesReply.from_json(raw)
        @mu.synchronize do
          if reply.term > @current_term
            step_down_locked(reply.term)
            return
          end
          return unless @role == Role::Leader && term == @current_term

          if reply.success
            new_match = reply.match_index
            @match_index[peer_id] = new_match if new_match > (@match_index[peer_id]? || 0_i64)
            @next_index[peer_id]  = new_match + 1
            advance_commit_index_locked
          else
            # reply.match_index is the follower's @log.last_index — a stable
            # value that doesn't move on rejection (no entries appended).  If we
            # set @next_index to it directly we'd loop forever.  Instead, jump
            # back by MAX_ENTRIES_PER_RPC from the current next_index so we
            # binary-sweep backward, finding the first matching term in O(n/200)
            # rounds rather than O(n).
            current = @next_index[peer_id]? || next_idx
            @next_index[peer_id] = {current - MAX_ENTRIES_PER_RPC, 1_i64}.max
          end
        end
      rescue
      end
    end

    private def advance_commit_index_locked
      majority = (@peers.size + 1) // 2 + 1
      highest_current = @commit_index
      n = @commit_index + 1
      while n <= @log.last_index
        count = 1 + @match_index.count { |_, mi| mi >= n }
        break unless count >= majority
        highest_current = n if @log.term_at(n) == @current_term
        n += 1
      end
      if highest_current > @commit_index
        @commit_index = highest_current
        save_persistent_state
        notify_apply
      end
    end

    # ── Read-index protocol (Raft §8) ─────────────────────────────────────────

    # Send an empty AppendEntries heartbeat to all peers and wait for majority
    # acknowledgement. Returns true if the leader confirmed it still holds the
    # majority; false on timeout or on discovering a higher-term reply.
    private def send_read_heartbeat(term : Int64) : Bool
      # Build per-peer heartbeat messages under @mu so we read consistent state.
      peer_msgs = @mu.synchronize do
        return false unless @role == Role::Leader && @current_term == term
        commit = @commit_index
        @peers.map do |peer_id, addr|
          ni   = @next_index[peer_id]? || @log.last_index + 1
          pt   = @log.term_at(ni - 1)
          {addr, AppendEntries.new(term, @node_id, ni - 1, pt, [] of LogEntry, commit)}
        end
      end
      return true if peer_msgs.empty?

      # Quorum from peers alone: (total_nodes // 2 + 1) - 1 self-vote
      needed = (peer_msgs.size + 1) // 2
      return true if needed == 0

      acks = Atomic(Int32).new(0)
      done = Channel(Bool).new(1)

      peer_msgs.each do |addr, msg|
        spawn do
          raw = send_rpc(addr, msg.to_wire)
          next unless raw
          begin
            reply = AppendEntriesReply.from_json(raw)
            if reply.term > term
              done.send(false) rescue nil
            elsif reply.success
              if acks.add(1) + 1 >= needed
                done.send(true) rescue nil
              end
            end
          rescue
          end
        end
      end

      select
      when result = done.receive
        result
      when timeout(300.milliseconds)
        false
      end
    end

    # Spin-wait until last_applied reaches target_index. Yields the fiber on
    # each iteration so the apply loop can make progress. Returns false on timeout.
    private def wait_applied(target_index : Int64, deadline_ms : Int32 = 500) : Bool
      deadline = Time.instant + deadline_ms.milliseconds
      while @mu.synchronize { @last_applied } < target_index
        return false if Time.instant > deadline
        Fiber.yield
      end
      true
    end

    # Non-blocking apply signal. If the channel is already full there are at
    # least 64 pending signals — the apply loop will process all committed
    # entries on its next wake-up, so dropping the signal is safe.
    # MUST NOT be called while holding @mu: the apply loop acquires @mu inside
    # apply_committed, so a blocking send under @mu would deadlock.
    private def notify_apply
      select
      when @apply_channel.send(nil)
      else
      end
    end

    # ── Apply loop ────────────────────────────────────────────────────────────

    private def spawn_apply_loop
      spawn do
        loop do
          begin
            select
            when @stop_channel.receive
              break
            when @apply_channel.receive
              begin
                apply_committed
              rescue ex
                STDERR.puts "FATAL apply_committed: #{ex.class}: #{ex.message}"
              end
            end
          rescue Channel::ClosedError
            break
          end
        end
      end
    end

    # How many entries to process before flushing state to disk during the
    # apply loop.  Larger batches are faster (fewer fsyncs) but risk losing more
    # un-applied entries on crash — the pager WAL isn't flushed until the batch
    # boundary.  200 is a safe trade-off: at most 200 entries are lost on
    # unplanned shutdown, which the replay path on restart can always recover
    # from the log (since snapshots truncate the log at multiples of SNAPSHOT_INTERVAL).
    private APPLY_FLUSH_INTERVAL = 200

    private def apply_committed
      # Loop until no more committed entries remain. This handles the case where
      # commit_index advances while we are mid-batch and notify_apply's
      # non-blocking send dropped the resulting signal.
      loop do
        commit = @mu.synchronize { @commit_index }
        break if @last_applied >= commit
        # Restrict this iteration to what the log can actually provide, so we
        # never iterate past nil entries into a potentially huge commit gap.
        batch_end = {commit, @log.last_index}.min
        batch_start = @last_applied
        while @last_applied < batch_end
          candidate = @last_applied + 1
          # A concurrent snapshot install (handle_install_snapshot Phase 4) may
          # truncate the log below candidate mid-batch.  Advancing @last_applied
          # past log.last_index would cause all subsequent entry_at calls to
          # return nil, incrementing @last_applied to batch_end with no SQL
          # applied — permanently losing every entry in that range.
          # Break here instead; the outer loop re-derives commit and log bounds
          # from current state, picking up at the correct position.
          break if candidate > @log.last_index
          @last_applied = candidate
          entry = @log.entry_at(@last_applied)
          next unless entry

          case entry.entry_type
          when "sql"
            next if entry.sql.empty?
            result = begin
              @sql_db.execute(entry.sql, [] of SQL::Value)
            rescue ex
              ex
            end
            if result.is_a?(Exception)
              STDERR.puts "[#{@node_id}] SQL error at index #{@last_applied}: " \
                          "#{result.class}: #{result.message}" if result.is_a?(Exception)
            end
            @pending_mu.synchronize do
              if pair = @pending.delete(@last_applied)
                expected_term, ch = pair
                if entry.term == expected_term
                  ch.send(result) rescue nil
                else
                  # A different leader overwrote the entry at this index; the
                  # original propose was for an uncommitted entry that got
                  # truncated.  Fail it so the client doesn't see a false "ok".
                  ch.send(DB::Error.new("overwritten by new leader at index #{@last_applied}")) rescue nil
                end
              end
            end
          when "add"
            apply_add_node(entry)
            @pending_config_mu.synchronize do
              if ch = @pending_config.delete(@last_applied)
                ch.send(nil) rescue nil
              end
            end
          end

          # Periodically flush progress to disk so a crash between snapshots
          # only loses at most APPLY_FLUSH_INTERVAL entries worth of SQL state.
          # This is critical for persistent mode: without periodic flushing, a
          # crash mid-batch discards ALL dirty WAL pages, and if snapshots have
          # truncated the log, those entries are permanently unrecoverable.
          if (@last_applied - batch_start) % APPLY_FLUSH_INTERVAL == 0
            @sql_db.commit_pager
          end
        end
        # Final flush at the end of the batch.
        @sql_db.commit_pager
        should_snapshot = @mu.synchronize do
          save_persistent_state
          @role == Role::Leader && @last_applied - @snapshot_last_index >= SNAPSHOT_INTERVAL
        end
        take_snapshot if should_snapshot
      end
    end

    private def replay_committed
      # Cap commit_index to what the log can actually provide, so we never
      # iterate past nil entries.  This matters when the state file's
      # commit_index was persisted before a snapshot truncated the log, or
      # when the node was killed before the log file had a chance to flush.
      replay_target = {@commit_index, @log.last_index}.min
      while @last_applied < replay_target
        @last_applied += 1
        entry = @log.entry_at(@last_applied)
        next unless entry
        case entry.entry_type
        when "sql"
          next if entry.sql.empty?
          @sql_db.execute(entry.sql, [] of SQL::Value) rescue nil
        when "add"
          apply_add_node(entry)
        end
      end
      # Flush replayed entries and persist last_applied so a second crash doesn't
      # re-replay them.
      @sql_db.commit_pager
      save_persistent_state
    end

    # Apply a committed "add" entry. Idempotent — safe to call on leader
    # (which already added the peer before proposing) and on followers.
    private def apply_add_node(entry : LogEntry)
      id          = entry.node_id    || return
      raft_addr   = entry.raft_addr  || return
      client_addr = entry.client_addr || ""
      return if id == @node_id  # the joining node itself doesn't add itself as a peer

      @mu.synchronize do
        unless @peers.has_key?(id)
          @peers[id] = raft_addr
          @client_peers[id] = client_addr
          # If we're the leader, initialise replication state for the new peer.
          if @role == Role::Leader
            @next_index[id]  = 1_i64
            @match_index[id] = 0_i64
          end
        end
        # Always clear the flag: a former leader that stepped down before the entry
        # committed would otherwise be stuck with @pending_config_change = true and
        # unable to add nodes again after re-winning leadership.
        @pending_config_change = false
      end
    end

    # ── Snapshot support ─────────────────────────────────────────────────────

    # On restart, if a snapshot exists and is newer than @last_applied, restore
    # the SQL database from the snapshot file and advance last_applied.
    private def apply_snapshot_if_present : Bool
      snap_path = @snapshot_path || return false
      return false unless File.exists?(snap_path)

      meta_path = snapshot_meta_path(snap_path)
      return false unless File.exists?(meta_path)

      meta = begin
        SnapshotMetadata.from_json(File.read(meta_path))
      rescue
        return false
      end

      return false unless meta.last_included_index >= @last_applied

      # Copy the snapshot DB file over the pager's main DB file and reload.
      @sql_db.replace_pager_from_file(snap_path)

      @last_applied = meta.last_included_index
      @commit_index = {meta.last_included_index, @commit_index}.max
      @snapshot_last_index = meta.last_included_index
      true
    end

    # Capture a snapshot of the current SQL state at @last_applied.
    # Called periodically by the leader from apply_committed.
    private def take_snapshot
      snap_path = @snapshot_path || return
      return if @last_applied <= @snapshot_last_index
      return if @last_applied == 0

      # Capture the index atomically so all snapshot operations agree on the
      # same boundary.  The apply loop runs concurrently and can advance
      # @last_applied between our flush_and_checkpoint and metadata write,
      # which would cause the metadata to claim a higher index than the
      # checkpointed DB file reflects.
      snapshot_index = @last_applied
      term = @log.term_at(snapshot_index)
      return if term == 0

      # 1. Flush all dirty pages to the WAL, then checkpoint into the main file.
      @sql_db.flush_and_checkpoint

      # 2. Copy the main DB file to a temp path, then atomically rename to the
      #    snapshot path.  Atomic rename prevents send_install_snapshot (which
      #    runs in a different fiber) from reading a partially-written file.
      db_path = @sql_db.pager.path
      return unless db_path && File.exists?(db_path)
      tmp_path = snap_path + ".tmp"
      @sql_db.copy_db_file(tmp_path)
      File.rename(tmp_path, snap_path)
      fsync_dir(snap_path)

      # 3. Write snapshot metadata using the captured index.
      meta = SnapshotMetadata.new(snapshot_index, term)
      write_json_atomic(snapshot_meta_path(snap_path), meta.to_json)

      # 4. Install snapshot into the log (truncate entries before the captured index).
      remaining = @log.entries_after(snapshot_index)
      @log.install_snapshot(snapshot_index, term, remaining)

      # 5. Persist state with @last_applied capped to snapshot_index so that
      #    apply_snapshot_if_present on restart finds
      #    meta.last_included_index >= @last_applied and applies the snapshot.
      #    Without this the persisted @last_applied (advanced by the apply loop)
      #    would exceed the snapshot boundary, causing the node to skip the
      #    snapshot and run with stale pager state.
      @snapshot_last_index = snapshot_index
      actual_applied = @last_applied
      @last_applied = snapshot_index
      save_persistent_state
      @last_applied = actual_applied
    end

    # Send a snapshot to a follower that is behind the snapshot boundary.
    # The file is split into SNAPSHOT_CHUNK_SIZE-byte chunks; each chunk is a
    # separate InstallSnapshot RPC.  The follower reassembles to a temp file and
    # applies it only when done=true arrives.
    private def send_install_snapshot(peer_id : String)
      addr = @peers[peer_id]? || return
      snap_path = @snapshot_path || return

      # Capture metadata and make a stable local copy of the snapshot file while
      # holding @mu, so a concurrent take_snapshot cannot replace snap_path between
      # the metadata read and the file open (TOCTOU fix).
      local_copy = snap_path + ".send_#{peer_id}"
      term, last_inc_idx, last_inc_term = @mu.synchronize do
        idx = @snapshot_last_index
        return if idx == 0
        File.copy(snap_path, local_copy) rescue return
        {@current_term, idx, @log.term_at(idx)}
      end

      buf = Bytes.new(SNAPSHOT_CHUNK_SIZE)

      File.open(local_copy, "rb") do |f|
        file_size = f.size
        loop do
          n = f.read(buf)
          break if n == 0

          chunk_offset = f.pos.to_i64 - n
          done = f.pos >= file_size

          encoded = Base64.strict_encode(buf[0, n])
          msg = InstallSnapshot.new(term, @node_id, last_inc_idx, last_inc_term,
                                    encoded, chunk_offset, done)
          raw = send_rpc(addr, msg.to_wire)
          return unless raw

          @mu.synchronize do
            reply = InstallSnapshotReply.from_json(raw)
            if reply.term > @current_term
              step_down_locked(reply.term)
              return
            end
            return unless @role == Role::Leader && @current_term == term
            return unless reply.success

            if done
              @match_index[peer_id] = last_inc_idx if last_inc_idx > (@match_index[peer_id]? || 0_i64)
              @next_index[peer_id]  = last_inc_idx + 1
              advance_commit_index_locked
            end
          end

          break if done
        end
      end
    rescue
    ensure
      File.delete(local_copy.not_nil!) rescue nil if local_copy
    end

    # Handle one InstallSnapshot chunk from a leader.
    # Non-final chunks (done=false) are appended to a .transfer temp file.
    # The final chunk (done=true) fsyncs the assembled file and applies it.
    #
    # @mu is held only for in-memory state validation and final state commit.
    # All File I/O runs outside @mu so the election timeout, heartbeat, and
    # apply-loop fibers are not blocked during disk writes.
    private def handle_install_snapshot(msg : InstallSnapshot) : InstallSnapshotReply
      # ── Phase 1: validate and update in-memory transfer state (under @mu) ──
      tmp_path, chunk, current_term = @mu.synchronize do
        if msg.term < @current_term
          return InstallSnapshotReply.new(@current_term, false)
        end
        step_down_locked(msg.term) if msg.term > @current_term

        @last_heartbeat = Time.instant
        @role = Role::Follower
        @leader_id = msg.leader_id

        tmp = (@snapshot_path || "/tmp/raft_snapshot_transfer.db").not_nil! + ".transfer"

        # Start fresh when the first chunk arrives or a new snapshot supersedes
        # an in-progress transfer (different last_included_index).
        if msg.offset == 0 || msg.last_included_index != @xfer_index
          @xfer_index  = msg.last_included_index
          @xfer_offset = 0_i64
        end

        # Reject out-of-order chunks so the leader knows to restart.
        if msg.offset != @xfer_offset
          @xfer_index  = 0_i64
          @xfer_offset = 0_i64
          return InstallSnapshotReply.new(@current_term, false)
        end

        decoded = Base64.decode(msg.data)
        @xfer_offset = msg.offset + decoded.size.to_i64

        {tmp, decoded, @current_term}
      end

      # ── Phase 2: write chunk to disk (outside @mu) ──────────────────────────
      if msg.offset == 0
        File.open(tmp_path, "wb") { |f| f.write(chunk) }
      else
        File.open(tmp_path, "r+b") do |f|
          f.seek(msg.offset)
          f.write(chunk)
        end
      end

      # Non-final chunk: acknowledge and wait for the next one.
      return InstallSnapshotReply.new(current_term, true) unless msg.done

      # ── Phase 3: final chunk — fsync, replace pager, persist (outside @mu) ──

      # Fsync the assembled transfer file before using it.
      File.open(tmp_path, "r") { |f| f.fsync }

      # Replace the pager's DB file with the snapshot and reload.
      @sql_db.replace_pager_from_file(tmp_path)

      # Persist snapshot to its canonical path BEFORE updating log metadata,
      # so a crash here leaves base_index unchanged and replay reconstructs.
      if snap_path = @snapshot_path
        File.copy(tmp_path, snap_path)
        File.open(snap_path, "r") { |f| f.fsync }
        fsync_dir(snap_path)
        meta = SnapshotMetadata.new(msg.last_included_index, msg.last_included_term)
        write_json_atomic(snapshot_meta_path(snap_path), meta.to_json)
      end
      File.delete(tmp_path) rescue nil

      # ── Phase 4: commit final state under @mu ───────────────────────────────
      @mu.synchronize do
        @xfer_index  = 0_i64
        @xfer_offset = 0_i64

        @log.install_snapshot(msg.last_included_index, msg.last_included_term, [] of LogEntry)

        @commit_index        = msg.last_included_index
        @last_applied        = msg.last_included_index
        @snapshot_last_index = msg.last_included_index

        save_persistent_state
      end

      InstallSnapshotReply.new(current_term, true)
    end

    # ── Persistent state ──────────────────────────────────────────────────────

    private def save_persistent_state
      path = @state_path || return
      state = PersistentState.new(@current_term, @voted_for, @commit_index, @last_applied)
      write_json_atomic(path, state.to_json)
    rescue ex
      STDERR.puts "[#{@node_id}] FATAL: could not persist Raft state: #{ex.class}: #{ex.message}"
      raise ex
    end

    private def load_persistent_state
      path = @state_path || return
      return unless File.exists?(path)
      state = PersistentState.from_json(File.read(path))
      @current_term = state.current_term
      @voted_for    = state.voted_for
      @commit_index = state.commit_index
      @last_applied = state.last_applied
    rescue
    end

    # ── Networking ────────────────────────────────────────────────────────────

    private def send_rpc(addr : String, wire : String) : String?
      host, port = split_addr(addr)
      sock = TCPSocket.new(host, port.to_i, connect_timeout: 0.2.seconds)
      sock.read_timeout  = 0.5.seconds
      sock.write_timeout = 0.5.seconds
      sock.puts(encrypt_wire(wire))
      raw = sock.gets
      return nil unless raw
      decrypt_wire(raw.chomp)
    rescue
      nil
    ensure
      sock.try &.close
    end

    private def encrypt_wire(s : String) : String
      if c = @cipher
        Base64.strict_encode(c.encrypt(s.to_slice))
      else
        s
      end
    end

    private def decrypt_wire(s : String) : String?
      if c = @cipher
        plain = c.decrypt(Base64.decode(s))
        plain ? String.new(plain) : nil
      else
        s
      end
    rescue
      nil
    end

    # ── Helpers ───────────────────────────────────────────────────────────────

    private def parse_peers(peers : Array(String)) : Hash(String, String)
      result = Hash(String, String).new
      peers.each do |spec|
        id, addr = spec.split("=", 2)
        result[id] = addr
      end
      result
    end

    private def write_json_atomic(path : String, json : String) : Nil
      tmp = path + ".tmp"
      File.open(tmp, "w") { |f| f.print(json); f.fsync }
      File.rename(tmp, path)
      fsync_dir(path)
    end

    private def snapshot_meta_path(snap_path : String) : String
      snap_path.sub(".db", ".json")
    end

    private def fsync_dir(path : String) : Nil
      File.open(File.dirname(path), "r") { |f| f.fsync }
    rescue
    end

    private def split_addr(addr : String) : Tuple(String, String)
      idx = addr.rindex(':') || raise "bad addr: #{addr}"
      {addr[0...idx], addr[(idx + 1)..]}
    end

    private def inline_args(sql : String, args : Array(SQL::Value)) : String
      return sql if args.empty?
      idx = 0
      String.build do |buf|
        sql.each_char do |ch|
          if ch == '?' && idx < args.size
            val = args[idx]
            idx += 1
            case val
            when Nil     then buf << "NULL"
            when Bool    then buf << (val ? "1" : "0")
            when Int64   then buf << val
            when Float64 then buf << val
            when String  then buf << "'"; buf << val.gsub("'", "''"); buf << "'"
            when Bytes
              buf << "X'"
              val.each { |b| buf << b.to_s(16).rjust(2, '0') }
              buf << "'"
            end
          else
            buf << ch
          end
        end
      end
    end
  end
end
