require "./spec_helper"
require "../src/raft_node_server"

PEER_RAFT_PORT   = 9001
PEER_CLIENT_PORT = 9002

describe "RaftNodeServer.build_peer_config" do
  describe "minimum cluster size guard" do
    it "accepts exactly the minimum number of IPs" do
      ips = ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
      specs, _, _ = RaftNodeServer.build_peer_config(ips, nil, PEER_RAFT_PORT, PEER_CLIENT_PORT, 3)
      specs.size.should eq 3
    end

    it "accepts more IPs than the minimum" do
      ips = ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5"]
      specs, _, _ = RaftNodeServer.build_peer_config(ips, nil, PEER_RAFT_PORT, PEER_CLIENT_PORT, 3)
      specs.size.should eq 5
    end

    it "rejects fewer IPs than the minimum" do
      ips = ["10.0.0.1", "10.0.0.2"]
      expect_raises(ArgumentError, /dns-minimum-cluster-size/) do
        RaftNodeServer.build_peer_config(ips, nil, PEER_RAFT_PORT, PEER_CLIENT_PORT, 3)
      end
    end

    it "rejects a single IP when minimum is 3" do
      expect_raises(ArgumentError) do
        RaftNodeServer.build_peer_config(["10.0.0.1"], nil, PEER_RAFT_PORT, PEER_CLIENT_PORT, 3)
      end
    end

    it "rejects an empty IP list" do
      expect_raises(ArgumentError, /empty/) do
        RaftNodeServer.build_peer_config([] of String, nil, PEER_RAFT_PORT, PEER_CLIENT_PORT, 1)
      end
    end

    it "accepts a single IP when minimum is 1" do
      specs, _, _ = RaftNodeServer.build_peer_config(["10.0.0.1"], nil, PEER_RAFT_PORT, PEER_CLIENT_PORT, 1)
      specs.size.should eq 1
    end
  end

  describe "own IP exclusion" do
    it "excludes own IP from peers" do
      ips = ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
      specs, client_map, own = RaftNodeServer.build_peer_config(ips, "10.0.0.1", PEER_RAFT_PORT, PEER_CLIENT_PORT, 3)
      own.should eq "10.0.0.1"
      specs.should_not contain("10.0.0.1=10.0.0.1:9001")
      specs.size.should eq 2
      client_map.has_key?("10.0.0.1").should be_false
    end

    it "treats all IPs as peers when own_ip is nil" do
      ips = ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
      specs, client_map, own = RaftNodeServer.build_peer_config(ips, nil, PEER_RAFT_PORT, PEER_CLIENT_PORT, 3)
      own.should be_nil
      specs.size.should eq 3
      client_map.size.should eq 3
    end

    it "handles own_ip not present in the IP list" do
      ips = ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
      specs, _, own = RaftNodeServer.build_peer_config(ips, "10.0.0.99", PEER_RAFT_PORT, PEER_CLIENT_PORT, 3)
      own.should eq "10.0.0.99"
      specs.size.should eq 3
    end
  end

  describe "peer spec format" do
    it "builds raft specs as ID=IP:PORT" do
      ips = ["10.0.0.2", "10.0.0.3"]
      specs, _, _ = RaftNodeServer.build_peer_config(ips, nil, PEER_RAFT_PORT, PEER_CLIENT_PORT, 2)
      specs.should contain("10.0.0.2=10.0.0.2:9001")
      specs.should contain("10.0.0.3=10.0.0.3:9001")
    end

    it "builds client map as IP => IP:PORT" do
      ips = ["10.0.0.2", "10.0.0.3"]
      _, client_map, _ = RaftNodeServer.build_peer_config(ips, nil, PEER_RAFT_PORT, PEER_CLIENT_PORT, 2)
      client_map["10.0.0.2"].should eq "10.0.0.2:9002"
      client_map["10.0.0.3"].should eq "10.0.0.3:9002"
    end

    it "respects custom ports" do
      ips = ["192.168.1.10"]
      specs, client_map, _ = RaftNodeServer.build_peer_config(ips, nil, 7001, 7002, 1)
      specs.first.should eq "192.168.1.10=192.168.1.10:7001"
      client_map["192.168.1.10"].should eq "192.168.1.10:7002"
    end
  end

  describe "single-node cluster" do
    it "results in no peers when own_ip is the only node" do
      ips = ["10.0.0.1"]
      specs, client_map, own = RaftNodeServer.build_peer_config(ips, "10.0.0.1", PEER_RAFT_PORT, PEER_CLIENT_PORT, 1)
      own.should eq "10.0.0.1"
      specs.should be_empty
      client_map.should be_empty
    end
  end
end
