require "json"
require "socket"
require "./log_entry"
require "./raft_log"
require "./messages"

module TrashPandaDB::Replication
  private ELECTION_TIMEOUT_MIN = 150
  private ELECTION_TIMEOUT_MAX = 600
  private HEARTBEAT_INTERVAL   =  50

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
    property commit_index : Int64  # persisted so we can replay on restart

    def initialize(@current_term = 0_i64, @voted_for = nil, @commit_index = 0_i64); end
  end

  class RaftNode
    getter node_id : String
    getter role : Role
    getter current_term : Int64
    getter leader_id : String?

    @peers : Hash(String, String)
    @last_heartbeat : Time::Instant
    @tcp_server : TCPServer?

    # peers: Array of "node_id=host:port"
    def initialize(
      @node_id : String,
      @listen_addr : String,   # "host:port"
      peers : Array(String),
      @sql_db : SQL::Database,
      data_dir : String? = nil
    )
      @peers = parse_peers(peers)
      @data_dir = data_dir
      @role = Role::Follower
      @current_term = 0_i64
      @voted_for = nil
      @leader_id = nil

      @log = RaftLog.new(data_dir)
      @commit_index = 0_i64
      @last_applied = 0_i64

      @next_index  = Hash(String, Int64).new
      @match_index = Hash(String, Int64).new

      @pending    = Hash(Int64, Channel(SQL::ExecuteResult | Exception)).new
      @pending_mu = Mutex.new

      @last_heartbeat = Time.instant
      @tcp_server = nil

      @state_path = data_dir ? File.join(data_dir.not_nil!, "raft_state.json") : nil
      load_persistent_state
      # Replay committed entries from a previous run into the fresh SQL database.
      replay_committed

      @stop_channel  = Channel(Nil).new
      @apply_channel = Channel(Nil).new(64)
      @mu = Mutex.new
    end

    # ── Public API ────────────────────────────────────────────────────────────

    def start : Nil
      spawn_server
      spawn_apply_loop
      spawn_election_timeout
    end

    def stop : Nil
      @stop_channel.close rescue nil
      @tcp_server.try &.close rescue nil
      @log.close
    end

    # Submit a write command.  Blocks until committed (or raises if not leader).
    def propose(sql : String, args : Array(SQL::Value) = [] of SQL::Value) : SQL::ExecuteResult
      raise DB::Error.new("not the leader (leader=#{@leader_id})") unless @role == Role::Leader

      inlined = inline_args(sql, args)
      reply_ch = Channel(SQL::ExecuteResult | Exception).new(1)
      @mu.synchronize do
        entry = @log.append(@current_term, inlined)
        @pending_mu.synchronize { @pending[entry.index] = reply_ch }
      end

      replicate_to_all

      result = reply_ch.receive
      raise result if result.is_a?(Exception)
      result.as(SQL::ExecuteResult)
    end

    # Execute a read against committed state.
    def query(sql : String, args : Array(SQL::Value) = [] of SQL::Value) : SQL::QueryResult
      raise DB::Error.new("not the leader (leader=#{@leader_id})") unless @role == Role::Leader
      result = @sql_db.execute(sql, args)
      result.as(SQL::QueryResult)
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
        msg = Replication.parse_message(line.strip)
        case msg
        when RequestVote
          reply = handle_request_vote(msg)
          sock.puts(reply.to_wire)
        when AppendEntries
          reply = handle_append_entries(msg)
          sock.puts(reply.to_wire)
        end
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
                next if @role == Role::Leader
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

    # IMPORTANT: must NOT be called while holding @mu (it acquires @mu internally).
    private def start_election
      @mu.synchronize do
        @role = Role::Candidate
        @current_term += 1
        @voted_for = @node_id
        # Reset the heartbeat timer so each retry gets its own random delay,
        # breaking the lockstep pattern that causes persistent split-votes.
        @last_heartbeat = Time.instant
        save_persistent_state

        # Single-node cluster: win immediately.
        if @peers.empty?
          become_leader_locked
          return
        end
      end

      term      = @mu.synchronize { @current_term }
      last_idx  = @mu.synchronize { @log.last_index }
      last_term = @mu.synchronize { @log.last_term }

      votes  = Atomic(Int32).new(1)  # vote for self
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

    # Called with @mu already held. No-op if already leader (idempotent guard).
    private def become_leader_locked
      return if @role == Role::Leader
      @role = Role::Leader
      @leader_id = @node_id
      @peers.each_key do |peer_id|
        @next_index[peer_id]  = @log.last_index + 1
        @match_index[peer_id] = 0_i64
      end
      # Append a no-op entry (empty sql) so any old-term entries in the log get
      # committed implicitly once this current-term entry reaches a majority
      # (Raft §5.4.2 — a leader cannot directly commit entries from prior terms).
      @log.append(@current_term, "") unless @peers.empty?
      # For single-node: commit all log entries immediately.
      if @peers.empty? && @log.last_index > @commit_index
        @commit_index = @log.last_index
        save_persistent_state
        @apply_channel.send(nil) rescue nil
      end
      spawn_heartbeat_loop
      # Replicate in a new fiber so we don't hold @mu across network I/O.
      spawn { replicate_to_all }
    end

    # Called with @mu already held.
    private def step_down_locked(new_term : Int64)
      @current_term = new_term
      @voted_for = nil
      @role = Role::Follower
      @last_heartbeat = Time.instant
      save_persistent_state
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
          @apply_channel.send(nil) rescue nil
        end

        AppendEntriesReply.new(@current_term, true, @log.last_index)
      end
    end

    # ── Replication ───────────────────────────────────────────────────────────

    # Called outside @mu; spawns per-peer fibers.
    private def replicate_to_all
      return unless @role == Role::Leader
      @peers.each_key { |peer_id| spawn replicate_to(peer_id) }
      # Single-node fast path: commit all new entries immediately (no peers to wait on).
      if @peers.empty?
        @mu.synchronize do
          if @log.last_index > @commit_index
            @commit_index = @log.last_index
            save_persistent_state
            @apply_channel.send(nil) rescue nil
          end
        end
      end
    end

    private def replicate_to(peer_id : String)
      addr = @peers[peer_id]? || return

      next_idx, prev_term, entries, term, commit = @mu.synchronize do
        ni       = @next_index[peer_id]? || @log.last_index + 1
        pt       = @log.term_at(ni - 1)
        en       = @log.entries_from(ni - 1)
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
            ni = @next_index[peer_id]? || 1_i64
            @next_index[peer_id] = {ni - 1, 1_i64}.max
          end
        end
      rescue
      end
    end

    # Called with @mu held.
    private def advance_commit_index_locked
      # Walk forward from commit_index+1 while a majority has replicated each entry.
      # Per Raft §5.4.2 we may only directly commit entries from @current_term;
      # older-term entries are implicitly committed when the highest current-term
      # entry is committed (Leader Completeness Property).
      highest_current = @commit_index
      n = @commit_index + 1
      while n <= @log.last_index
        count = 1 + @match_index.count { |_, mi| mi >= n }
        break unless count > (@peers.size + 1) // 2
        highest_current = n if @log.term_at(n) == @current_term
        n += 1
      end
      if highest_current > @commit_index
        @commit_index = highest_current
        save_persistent_state
        @apply_channel.send(nil) rescue nil
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
              apply_committed
            end
          rescue Channel::ClosedError
            break
          end
        end
      end
    end

    private def apply_committed
      commit = @mu.synchronize { @commit_index }
      while @last_applied < commit
        @last_applied += 1
        entry = @log.entry_at(@last_applied)
        next unless entry
        next if entry.sql.empty?

        result = begin
          @sql_db.execute(entry.sql, [] of SQL::Value)
        rescue ex
          ex
        end

        @pending_mu.synchronize do
          if ch = @pending.delete(@last_applied)
            ch.send(result) rescue nil
          end
        end
      end
    end

    # Synchronously replay entries 1..@commit_index into the SQL db.
    # Called during initialize so the db is warm before start.
    private def replay_committed
      while @last_applied < @commit_index
        @last_applied += 1
        entry = @log.entry_at(@last_applied)
        next unless entry
        next if entry.sql.empty?
        @sql_db.execute(entry.sql, [] of SQL::Value) rescue nil
      end
    end

    # ── Persistent state ──────────────────────────────────────────────────────

    private def save_persistent_state
      path = @state_path || return
      state = PersistentState.new(@current_term, @voted_for, @commit_index)
      tmp = path + ".tmp"
      File.write(tmp, state.to_json)
      File.rename(tmp, path)
    rescue
    end

    private def load_persistent_state
      path = @state_path || return
      return unless File.exists?(path)
      state = PersistentState.from_json(File.read(path))
      @current_term = state.current_term
      @voted_for    = state.voted_for
      @commit_index = state.commit_index
    rescue
    end

    # ── Networking ────────────────────────────────────────────────────────────

    private def send_rpc(addr : String, wire : String) : String?
      host, port = split_addr(addr)
      sock = TCPSocket.new(host, port.to_i, connect_timeout: 0.2.seconds)
      sock.read_timeout  = 0.5.seconds
      sock.write_timeout = 0.5.seconds
      sock.puts(wire)
      reply = sock.gets
      sock.close
      reply
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

    private def split_addr(addr : String) : Tuple(String, String)
      idx = addr.rindex(':') || raise "bad addr: #{addr}"
      {addr[0...idx], addr[(idx + 1)..]}
    end

    # Inline SQL::Value args into a SQL string (? → literal values).
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
