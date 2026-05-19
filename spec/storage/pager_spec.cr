require "./spec_helper"

describe TrashPandaDB::Storage::Pager do
  describe "in-memory mode (nil path)" do
    it "starts with page_count 0" do
      pager = TrashPandaDB::Storage::Pager.new(nil)
      pager.page_count.should eq 0_u32
    end

    it "allocate_page increments page_count" do
      pager = TrashPandaDB::Storage::Pager.new(nil)
      pager.allocate_page.should eq 1_u32
      pager.allocate_page.should eq 2_u32
      pager.page_count.should eq 2_u32
    end

    it "read_page returns zeroed buffer for new page" do
      pager = TrashPandaDB::Storage::Pager.new(nil)
      pager.allocate_page
      data = pager.read_page(1_u32)
      data.size.should eq TrashPandaDB::Storage::PAGE_SIZE
      data.all?(&.zero?).should be_true
    end

    it "write and read page round-trips" do
      pager = TrashPandaDB::Storage::Pager.new(nil)
      pager.allocate_page
      buf = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0xCA_u8)
      pager.write_page(1_u32, buf)
      result = pager.read_page(1_u32)
      result[0].should eq 0xCA_u8
    end

    it "write_page extends page_count when page_no > page_count" do
      pager = TrashPandaDB::Storage::Pager.new(nil)
      buf = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0x01_u8)
      pager.write_page(3_u32, buf)
      pager.page_count.should eq 3_u32
    end

    it "commit promotes dirty to committed" do
      pager = TrashPandaDB::Storage::Pager.new(nil)
      buf = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0x55_u8)
      pager.write_page(1_u32, buf)
      pager.commit
      result = pager.read_page(1_u32)
      result[0].should eq 0x55_u8
    end

    it "rollback discards dirty writes" do
      pager = TrashPandaDB::Storage::Pager.new(nil)
      buf = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0xAA_u8)
      pager.write_page(1_u32, buf)
      pager.rollback
      result = pager.read_page(1_u32)
      result.all?(&.zero?).should be_true
    end

    it "rollback preserves previously committed data" do
      pager = TrashPandaDB::Storage::Pager.new(nil)
      buf1 = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0x11_u8)
      pager.write_page(1_u32, buf1)
      pager.commit

      buf2 = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0x22_u8)
      pager.write_page(1_u32, buf2)
      pager.rollback

      result = pager.read_page(1_u32)
      result[0].should eq 0x11_u8
    end

    it "multiple pages are isolated" do
      pager = TrashPandaDB::Storage::Pager.new(nil)
      (1_u32..4_u32).each do |n|
        buf = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, n.to_u8)
        pager.write_page(n, buf)
      end
      pager.commit
      (1_u32..4_u32).each do |n|
        pager.read_page(n)[0].should eq n.to_u8
      end
    end

    it "raises on page_no 0" do
      pager = TrashPandaDB::Storage::Pager.new(nil)
      expect_raises(ArgumentError) { pager.read_page(0_u32) }
      expect_raises(ArgumentError) { pager.write_page(0_u32, Bytes.new(TrashPandaDB::Storage::PAGE_SIZE)) }
    end
  end

  describe "file-backed mode" do
    it "creates DB file with correct magic" do
      with_tmp_path do |path|
        pager = TrashPandaDB::Storage::Pager.new(path)
        pager.close
        File.exists?(path).should be_true
        magic = File.read(path)[0, 8]
        magic.should eq TrashPandaDB::Storage::DB_MAGIC
      end
    end

    it "write + commit + reopen preserves data" do
      with_tmp_path do |path|
        pager1 = TrashPandaDB::Storage::Pager.new(path)
        buf = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE)
        buf[0] = 0xBB_u8
        buf[1] = 0xCC_u8
        pager1.write_page(1_u32, buf)
        pager1.commit
        pager1.checkpoint
        pager1.close

        pager2 = TrashPandaDB::Storage::Pager.new(path)
        result = pager2.read_page(1_u32)
        result[0].should eq 0xBB_u8
        result[1].should eq 0xCC_u8
        pager2.close
      end
    end

    it "page_count is persisted across reopen" do
      with_tmp_path do |path|
        pager1 = TrashPandaDB::Storage::Pager.new(path)
        3.times { pager1.allocate_page }
        (1_u32..3_u32).each do |n|
          pager1.write_page(n, Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, n.to_u8))
        end
        pager1.commit
        pager1.checkpoint
        pager1.close

        pager2 = TrashPandaDB::Storage::Pager.new(path)
        pager2.page_count.should eq 3_u32
        pager2.close
      end
    end

    it "WAL replay on crash-reopen returns committed data" do
      with_tmp_path do |path|
        pager1 = TrashPandaDB::Storage::Pager.new(path)
        buf = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0xEE_u8)
        pager1.write_page(1_u32, buf)
        pager1.commit
        # do NOT checkpoint — simulates crash after WAL commit but before checkpoint
        pager1.close

        pager2 = TrashPandaDB::Storage::Pager.new(path)
        result = pager2.read_page(1_u32)
        result[0].should eq 0xEE_u8
        pager2.close
      end
    end

    it "rollback does not persist data across reopen" do
      with_tmp_path do |path|
        pager1 = TrashPandaDB::Storage::Pager.new(path)
        buf = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0xFF_u8)
        pager1.write_page(1_u32, buf)
        pager1.rollback
        pager1.close

        pager2 = TrashPandaDB::Storage::Pager.new(path)
        result = pager2.read_page(1_u32)
        result.all?(&.zero?).should be_true
        pager2.close
      end
    end
  end
end
