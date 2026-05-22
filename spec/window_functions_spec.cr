require "./spec_helper"

private def setup_scores(db : DB::Database)
  db.exec "CREATE TABLE scores (id INTEGER PRIMARY KEY, player TEXT, dept TEXT, score INTEGER)"
  [
    {"Alice",   "eng",  90},
    {"Bob",     "eng",  85},
    {"Carol",   "eng",  90},
    {"Dave",    "sales", 70},
    {"Eve",     "sales", 80},
    {"Frank",   "sales", 75},
  ].each_with_index do |(player, dept, score), i|
    db.exec "INSERT INTO scores (player, dept, score) VALUES (?, ?, ?)", player, dept, score
  end
end

describe "Window functions" do
  describe "ROW_NUMBER" do
    it "assigns sequential numbers globally" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        [10, 30, 20].each_with_index { |v, i| db.exec "INSERT INTO t (v) VALUES (?)", v }
        rows = db.query_all "SELECT v, ROW_NUMBER() OVER (ORDER BY v) AS rn FROM t ORDER BY v", as: {Int32, Int64}
        rows.should eq([{10, 1_i64}, {20, 2_i64}, {30, 3_i64}])
      end
    end

    it "assigns sequential numbers per partition" do
      with_mem_db do |db|
        setup_scores(db)
        rows = db.query_all(
          "SELECT player, dept, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY score DESC) AS rn FROM scores ORDER BY dept, rn",
          as: {String, String, Int64}
        )
        eng_rows   = rows.select { |_, d, _| d == "eng" }.map { |p, _, rn| {p, rn} }
        sales_rows = rows.select { |_, d, _| d == "sales" }.map { |p, _, rn| {p, rn} }

        eng_rns = eng_rows.map(&.last)
        eng_rns.should eq([1_i64, 2_i64, 3_i64])

        sales_rns = sales_rows.map(&.last)
        sales_rns.should eq([1_i64, 2_i64, 3_i64])
      end
    end

    it "works with no PARTITION BY or ORDER BY (arbitrary order, all unique)" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY)"
        3.times { |i| db.exec "INSERT INTO t (id) VALUES (?)", i + 1 }
        rows = db.query_all "SELECT ROW_NUMBER() OVER () AS rn FROM t", as: Int64
        rows.sort.should eq([1_i64, 2_i64, 3_i64])
      end
    end
  end

  describe "RANK" do
    it "assigns same rank to ties, gaps after" do
      with_mem_db do |db|
        setup_scores(db)
        rows = db.query_all(
          "SELECT player, score, RANK() OVER (PARTITION BY dept ORDER BY score DESC) AS rnk FROM scores WHERE dept = 'eng' ORDER BY score DESC",
          as: {String, Int32, Int64}
        )
        # Alice and Carol both have 90 → rank 1; Bob has 85 → rank 3
        ranks = rows.map { |_, _, r| r }
        ranks[0].should eq(1_i64)
        ranks[1].should eq(1_i64)
        ranks[2].should eq(3_i64)
      end
    end
  end

  describe "DENSE_RANK" do
    it "assigns same rank to ties, no gaps" do
      with_mem_db do |db|
        setup_scores(db)
        rows = db.query_all(
          "SELECT player, score, DENSE_RANK() OVER (PARTITION BY dept ORDER BY score DESC) AS dr FROM scores WHERE dept = 'eng' ORDER BY score DESC",
          as: {String, Int32, Int64}
        )
        # Alice and Carol both score 90 → dense_rank 1; Bob has 85 → dense_rank 2
        dr_vals = rows.map { |_, _, dr| dr }
        dr_vals[0].should eq(1_i64)
        dr_vals[1].should eq(1_i64)
        dr_vals[2].should eq(2_i64)
      end
    end
  end

  describe "LAG" do
    it "returns value from previous row" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        [1, 2, 3, 4].each { |v| db.exec "INSERT INTO t (v) VALUES (?)", v }
        rows = db.query_all "SELECT v, LAG(v, 1) OVER (ORDER BY v) AS prev FROM t ORDER BY v", as: {Int32, Int32?}
        rows.should eq([{1, nil}, {2, 1}, {3, 2}, {4, 3}])
      end
    end

    it "uses default value when out of range" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        [10, 20].each { |v| db.exec "INSERT INTO t (v) VALUES (?)", v }
        rows = db.query_all "SELECT v, LAG(v, 1, 0) OVER (ORDER BY v) AS prev FROM t ORDER BY v", as: {Int32, Int32}
        rows.should eq([{10, 0}, {20, 10}])
      end
    end

    it "works per partition" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, grp TEXT, v INTEGER)"
        [{"a", 1}, {"a", 2}, {"b", 10}, {"b", 20}].each { |g, v| db.exec "INSERT INTO t (grp, v) VALUES (?, ?)", g, v }
        rows = db.query_all(
          "SELECT grp, v, LAG(v, 1) OVER (PARTITION BY grp ORDER BY v) AS prev FROM t ORDER BY grp, v",
          as: {String, Int32, Int32?}
        )
        rows.should eq([{"a", 1, nil}, {"a", 2, 1}, {"b", 10, nil}, {"b", 20, 10}])
      end
    end
  end

  describe "LEAD" do
    it "returns value from next row" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        [1, 2, 3, 4].each { |v| db.exec "INSERT INTO t (v) VALUES (?)", v }
        rows = db.query_all "SELECT v, LEAD(v, 1) OVER (ORDER BY v) AS nxt FROM t ORDER BY v", as: {Int32, Int32?}
        rows.should eq([{1, 2}, {2, 3}, {3, 4}, {4, nil}])
      end
    end
  end

  describe "SUM OVER" do
    it "computes whole-partition sum (no ORDER BY)" do
      with_mem_db do |db|
        setup_scores(db)
        rows = db.query_all(
          "SELECT player, dept, SUM(score) OVER (PARTITION BY dept) AS dept_total FROM scores ORDER BY dept, player",
          as: {String, String, Int64}
        )
        eng_totals = rows.select { |_, d, _| d == "eng" }.map(&.last)
        eng_totals.each { |t| t.should eq(265_i64) }  # 90+85+90

        sales_totals = rows.select { |_, d, _| d == "sales" }.map(&.last)
        sales_totals.each { |t| t.should eq(225_i64) }  # 70+80+75
      end
    end

    it "computes running sum with ORDER BY" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        [1, 2, 3, 4].each { |v| db.exec "INSERT INTO t (v) VALUES (?)", v }
        rows = db.query_all "SELECT v, SUM(v) OVER (ORDER BY v) AS running FROM t ORDER BY v", as: {Int32, Int64}
        rows.should eq([{1, 1_i64}, {2, 3_i64}, {3, 6_i64}, {4, 10_i64}])
      end
    end

    it "SUM OVER without PARTITION or ORDER BY sums everything" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        [10, 20, 30].each { |v| db.exec "INSERT INTO t (v) VALUES (?)", v }
        rows = db.query_all "SELECT v, SUM(v) OVER () AS total FROM t ORDER BY v", as: {Int32, Int64}
        rows.each { |_, total| total.should eq(60_i64) }
      end
    end
  end

  describe "AVG OVER" do
    it "computes partition average" do
      with_mem_db do |db|
        setup_scores(db)
        rows = db.query_all(
          "SELECT player, dept, AVG(score) OVER (PARTITION BY dept) AS dept_avg FROM scores WHERE dept = 'eng' ORDER BY player",
          as: {String, String, Float64}
        )
        rows.each { |_, _, avg| avg.should be_close(265.0 / 3, 0.001) }
      end
    end
  end

  describe "COUNT OVER" do
    it "counts rows in partition" do
      with_mem_db do |db|
        setup_scores(db)
        rows = db.query_all(
          "SELECT player, dept, COUNT(score) OVER (PARTITION BY dept) AS cnt FROM scores ORDER BY dept, player",
          as: {String, String, Int64}
        )
        eng_cnts = rows.select { |_, d, _| d == "eng" }.map(&.last)
        eng_cnts.each { |c| c.should eq(3_i64) }
        sales_cnts = rows.select { |_, d, _| d == "sales" }.map(&.last)
        sales_cnts.each { |c| c.should eq(3_i64) }
      end
    end
  end

  describe "MIN / MAX OVER" do
    it "returns partition min and max" do
      with_mem_db do |db|
        setup_scores(db)
        rows = db.query_all(
          "SELECT dept, MIN(score) OVER (PARTITION BY dept) AS mn, MAX(score) OVER (PARTITION BY dept) AS mx FROM scores WHERE dept = 'eng' ORDER BY id",
          as: {String, Int32, Int32}
        )
        rows.each do |_, mn, mx|
          mn.should eq(85)
          mx.should eq(90)
        end
      end
    end
  end

  describe "FIRST_VALUE / LAST_VALUE" do
    it "returns first value of sorted partition" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, grp TEXT, v INTEGER)"
        [{"a", 3}, {"a", 1}, {"a", 2}].each { |g, v| db.exec "INSERT INTO t (grp, v) VALUES (?, ?)", g, v }
        rows = db.query_all(
          "SELECT v, FIRST_VALUE(v) OVER (PARTITION BY grp ORDER BY v) AS fv FROM t ORDER BY v",
          as: {Int32, Int32}
        )
        rows.each { |_, fv| fv.should eq(1) }
      end
    end

    it "returns last value of sorted partition" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, grp TEXT, v INTEGER)"
        [{"a", 3}, {"a", 1}, {"a", 2}].each { |g, v| db.exec "INSERT INTO t (grp, v) VALUES (?, ?)", g, v }
        rows = db.query_all(
          "SELECT v, LAST_VALUE(v) OVER (PARTITION BY grp ORDER BY v) AS lv FROM t ORDER BY v",
          as: {Int32, Int32}
        )
        rows.each { |_, lv| lv.should eq(3) }
      end
    end
  end

  describe "NTILE" do
    it "divides rows into N buckets" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        [1, 2, 3, 4, 5, 6].each { |v| db.exec "INSERT INTO t (v) VALUES (?)", v }
        rows = db.query_all "SELECT v, NTILE(3) OVER (ORDER BY v) AS bucket FROM t ORDER BY v", as: {Int32, Int64}
        buckets = rows.map(&.last)
        buckets.should eq([1_i64, 1_i64, 2_i64, 2_i64, 3_i64, 3_i64])
      end
    end
  end

  describe "multiple window functions in one query" do
    it "computes several window exprs simultaneously" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        [10, 20, 30].each { |v| db.exec "INSERT INTO t (v) VALUES (?)", v }
        rows = db.query_all(
          "SELECT v, ROW_NUMBER() OVER (ORDER BY v) AS rn, SUM(v) OVER () AS total FROM t ORDER BY v",
          as: {Int32, Int64, Int64}
        )
        rows.should eq([{10, 1_i64, 60_i64}, {20, 2_i64, 60_i64}, {30, 3_i64, 60_i64}])
      end
    end
  end

  describe "frame clause" do
    it "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW = running sum" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        [1, 2, 3].each { |v| db.exec "INSERT INTO t (v) VALUES (?)", v }
        rows = db.query_all(
          "SELECT v, SUM(v) OVER (ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS rs FROM t ORDER BY v",
          as: {Int32, Int64}
        )
        rows.should eq([{1, 1_i64}, {2, 3_i64}, {3, 6_i64}])
      end
    end

    it "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING = whole partition" do
      with_mem_db do |db|
        db.exec "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"
        [1, 2, 3].each { |v| db.exec "INSERT INTO t (v) VALUES (?)", v }
        rows = db.query_all(
          "SELECT v, SUM(v) OVER (ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS total FROM t ORDER BY v",
          as: {Int32, Int64}
        )
        rows.each { |_, total| total.should eq(6_i64) }
      end
    end
  end
end
