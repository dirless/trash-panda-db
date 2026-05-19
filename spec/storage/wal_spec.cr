require "./spec_helper"

describe TrashPandaDB::Storage::WAL do
  describe "in-memory (nil path)" do
    it "starts empty" do
      wal = TrashPandaDB::Storage::WAL.new(nil)
      wal.committed.empty?.should be_true
      wal.dirty.empty?.should be_true
    end

    it "write_page stages into dirty" do
      wal = TrashPandaDB::Storage::WAL.new(nil)
      data = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0xAB_u8)
      wal.write_page(1_u32, data)
      wal.dirty.has_key?(1_u32).should be_true
    end

    it "read_page returns dirty data before commit" do
      wal = TrashPandaDB::Storage::WAL.new(nil)
      data = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0x42_u8)
      wal.write_page(1_u32, data)
      result = wal.read_page(1_u32)
      result.should_not be_nil
      result.not_nil![0].should eq 0x42_u8
    end

    it "commit promotes dirty to committed" do
      wal = TrashPandaDB::Storage::WAL.new(nil)
      data = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0x01_u8)
      wal.write_page(1_u32, data)
      wal.commit
      wal.dirty.empty?.should be_true
      wal.committed.has_key?(1_u32).should be_true
    end

    it "rollback discards dirty writes" do
      wal = TrashPandaDB::Storage::WAL.new(nil)
      data = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0xFF_u8)
      wal.write_page(1_u32, data)
      wal.rollback
      wal.dirty.empty?.should be_true
      wal.read_page(1_u32).should be_nil
    end

    it "read_page returns committed data after rollback of dirty" do
      wal = TrashPandaDB::Storage::WAL.new(nil)
      committed_data = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0x10_u8)
      wal.write_page(1_u32, committed_data)
      wal.commit

      dirty_data = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0xFF_u8)
      wal.write_page(1_u32, dirty_data)
      wal.rollback

      result = wal.read_page(1_u32)
      result.should_not be_nil
      result.not_nil![0].should eq 0x10_u8
    end

    it "dirty write shadows committed data" do
      wal = TrashPandaDB::Storage::WAL.new(nil)
      data1 = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0x01_u8)
      wal.write_page(1_u32, data1)
      wal.commit

      data2 = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0x02_u8)
      wal.write_page(1_u32, data2)

      result = wal.read_page(1_u32)
      result.not_nil![0].should eq 0x02_u8
    end

    it "commit is a no-op when dirty is empty" do
      wal = TrashPandaDB::Storage::WAL.new(nil)
      wal.commit
      wal.committed.empty?.should be_true
    end

    it "multiple pages tracked independently" do
      wal = TrashPandaDB::Storage::WAL.new(nil)
      (1_u32..5_u32).each do |n|
        data = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, n.to_u8)
        wal.write_page(n, data)
      end
      wal.commit
      (1_u32..5_u32).each do |n|
        wal.read_page(n).not_nil![0].should eq n.to_u8
      end
    end
  end

  describe "file-backed WAL" do
    it "creates WAL file with correct magic" do
      with_tmp_path do |path|
        wal_path = "#{path}-wal"
        wal = TrashPandaDB::Storage::WAL.new(wal_path)
        File.exists?(wal_path).should be_true
        magic = File.read(wal_path)[0, 8]
        magic.should eq TrashPandaDB::Storage::WAL_MAGIC
        wal.close
      end
    end

    it "persists committed frames and replays on reopen" do
      with_tmp_path do |path|
        wal_path = "#{path}-wal"

        wal1 = TrashPandaDB::Storage::WAL.new(wal_path)
        data = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0xBE_u8)
        wal1.write_page(1_u32, data)
        wal1.commit
        wal1.close

        wal2 = TrashPandaDB::Storage::WAL.new(wal_path)
        result = wal2.read_page(1_u32)
        result.should_not be_nil
        result.not_nil![0].should eq 0xBE_u8
        wal2.close
      end
    end

    it "does not replay frames past a crash (no commit marker)" do
      with_tmp_path do |path|
        wal_path = "#{path}-wal"

        wal1 = TrashPandaDB::Storage::WAL.new(wal_path)
        data = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0xDE_u8)
        wal1.write_page(1_u32, data)
        # deliberately no commit — simulates crash
        wal1.close

        wal2 = TrashPandaDB::Storage::WAL.new(wal_path)
        wal2.read_page(1_u32).should be_nil
        wal2.close
      end
    end

    it "checkpoint clears committed frames and truncates WAL" do
      with_tmp_path do |path|
        wal_path = "#{path}-wal"
        db_file  = File.open(path, "w+b")

        wal = TrashPandaDB::Storage::WAL.new(wal_path)
        data = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE, 0x77_u8)
        wal.write_page(1_u32, data)
        wal.commit
        wal.checkpoint(db_file, 1_u32)

        wal.committed.empty?.should be_true
        db_file.close
        wal.close
      end
    end
  end
end
