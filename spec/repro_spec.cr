require "./spec_helper"

describe "IndexError repro - Granite-style queries" do
  it "handles table-qualified SELECT with ORDER BY" do
    with_mem_db do |db|
      db.exec "CREATE TABLE health_checks (id INTEGER PRIMARY KEY, customer_id INTEGER, node_id INTEGER, status TEXT, http_status INTEGER, response_time_ms INTEGER, tenant_count INTEGER, user_count INTEGER, error TEXT, data_updated_at TEXT, active_agents INTEGER, agents_json TEXT, checked_at TEXT)"
      db.exec "INSERT INTO health_checks (customer_id, node_id, status, checked_at) VALUES (1, 1, 'up', '2026-05-24T15:00:00.000000Z')"
      db.exec "INSERT INTO health_checks (customer_id, node_id, status, checked_at) VALUES (1, 1, 'up', '2026-05-24T15:01:00.000000Z')"

      # Granite generates table-qualified column names with double-quote identifiers
      sql = %q(SELECT "health_checks"."id", "health_checks"."customer_id", "health_checks"."node_id", "health_checks"."status", "health_checks"."http_status", "health_checks"."response_time_ms", "health_checks"."tenant_count", "health_checks"."user_count", "health_checks"."error", "health_checks"."data_updated_at", "health_checks"."active_agents", "health_checks"."agents_json", "health_checks"."checked_at" FROM "health_checks" WHERE customer_id = ? AND node_id = ? ORDER BY checked_at DESC LIMIT 1)
      rows = db.query_all(sql, 1_i64, 1_i64, as: {Int64, Int64, Int64, String, Int32?, Int32?, Int32?, Int32?, String?, String?, Int32?, String?, String})
      rows.size.should eq(1)
      rows[0][12].should eq("2026-05-24T15:01:00.000000Z")
    end
  end

  it "handles the prune DELETE with Time-like string" do
    with_mem_db do |db|
      db.exec "CREATE TABLE health_checks (id INTEGER PRIMARY KEY, customer_id INTEGER, node_id INTEGER, status TEXT, checked_at TEXT)"
      db.exec "INSERT INTO health_checks (customer_id, node_id, status, checked_at) VALUES (1, 1, 'up', '2026-05-23T10:00:00.000000Z')"
      db.exec "INSERT INTO health_checks (customer_id, node_id, status, checked_at) VALUES (1, 1, 'up', '2026-05-24T15:00:00.000000Z')"

      # Granite generates: DELETE FROM "health_checks" WHERE checked_at < ?
      db.exec %q(DELETE FROM "health_checks" WHERE checked_at < ?), "2026-05-24T00:00:00.000000Z"

      count = db.scalar(%q(SELECT COUNT(*) FROM "health_checks")).as(Int64)
      count.should eq(1_i64)
    end
  end

  it "handles the full status route simulation" do
    with_mem_db do |db|
      db.exec "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, label TEXT, hmac_secret TEXT, aws_account_id TEXT)"
      db.exec "CREATE TABLE nodes (id INTEGER PRIMARY KEY, name TEXT, ip TEXT, region TEXT, is_primary INTEGER, services_json TEXT, syncthing_status_json TEXT, cpu_count INTEGER, memory_gb INTEGER, free_memory_mb INTEGER, free_disk_gb INTEGER, load_5m REAL, last_probed_at TEXT, probe_error TEXT)"
      db.exec "CREATE TABLE health_checks (id INTEGER PRIMARY KEY, customer_id INTEGER, node_id INTEGER, status TEXT, http_status INTEGER, response_time_ms INTEGER, tenant_count INTEGER, user_count INTEGER, error TEXT, data_updated_at TEXT, active_agents INTEGER, agents_json TEXT, checked_at TEXT)"

      db.exec "INSERT INTO customers (name, label) VALUES ('abc-5000', 'Test Corp')"
      db.exec "INSERT INTO nodes (name, ip, region, is_primary) VALUES ('node1', '1.2.3.4', 'us-east', 1)"
      db.exec "INSERT INTO health_checks (customer_id, node_id, status, checked_at) VALUES (1, 1, 'up', '2026-05-24T15:00:00.000000Z')"

      # Node.all
      nodes = db.query_all(%q(SELECT "nodes"."id", "nodes"."name", "nodes"."ip", "nodes"."region", "nodes"."is_primary", "nodes"."services_json", "nodes"."syncthing_status_json", "nodes"."cpu_count", "nodes"."memory_gb", "nodes"."free_memory_mb", "nodes"."free_disk_gb", "nodes"."load_5m", "nodes"."last_probed_at", "nodes"."probe_error" FROM "nodes"), as: {Int64, String, String, String?, Int64?, String?, String?, Int64?, Int64?, Int64?, Int64?, Float64?, String?, String?})
      nodes.size.should eq(1)

      # Customer.all
      customers = db.query_all(%q(SELECT "customers"."id", "customers"."name", "customers"."label", "customers"."hmac_secret", "customers"."aws_account_id" FROM "customers"), as: {Int64, String, String?, String?, String?})
      customers.size.should eq(1)

      # HealthCheck.first per customer/node
      hc = db.query_all(%q(SELECT "health_checks"."id", "health_checks"."customer_id", "health_checks"."node_id", "health_checks"."status", "health_checks"."http_status", "health_checks"."response_time_ms", "health_checks"."tenant_count", "health_checks"."user_count", "health_checks"."error", "health_checks"."data_updated_at", "health_checks"."active_agents", "health_checks"."agents_json", "health_checks"."checked_at" FROM "health_checks" WHERE customer_id = ? AND node_id = ? ORDER BY checked_at DESC LIMIT 1), 1_i64, 1_i64, as: {Int64, Int64, Int64, String, Int32?, Int32?, Int32?, Int32?, String?, String?, Int32?, String?, String})
      hc.size.should eq(1)
    end
  end
end
