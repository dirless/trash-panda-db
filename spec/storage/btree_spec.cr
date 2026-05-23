require "../spec_helper"

def make_pager
  TrashPandaDB::Storage::Pager.new(nil)  # in-memory
end

describe TrashPandaDB::Storage::BTree do
  it "inserts and searches single entry" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    key = Bytes[1, 2, 3]
    val = Bytes[9, 8, 7]
    tree.insert(key, val)
    tree.search(key).not_nil!.to_a.should eq val.to_a
  end

  it "returns nil for missing key" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    tree.search(Bytes[1]).should be_nil
  end

  it "scans entries in key order" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    codec = TrashPandaDB::Storage::RowCodec
    100.times { |i| tree.insert(codec.encode_key(i.to_i64), Bytes[i.to_u8]) }
    keys = [] of Int64
    tree.scan { |k, _| keys << codec.decode_key(k) }
    keys.should eq (0...100).map(&.to_i64)
  end

  it "deletes entries" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    codec = TrashPandaDB::Storage::RowCodec
    tree.insert(codec.encode_key(1_i64), Bytes[1])
    tree.insert(codec.encode_key(2_i64), Bytes[2])
    tree.delete(codec.encode_key(1_i64))
    tree.search(codec.encode_key(1_i64)).should be_nil
    tree.search(codec.encode_key(2_i64)).should_not be_nil
  end

  it "handles insertions that cause leaf splits" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    codec = TrashPandaDB::Storage::RowCodec
    # 500 entries of 100 bytes each should force multiple splits
    500.times do |i|
      val = Bytes.new(100, (i % 256).to_u8)
      tree.insert(codec.encode_key(i.to_i64), val)
    end
    count = 0
    tree.scan { |_, _| count += 1 }
    count.should eq 500
    # Verify a sample
    tree.search(codec.encode_key(250_i64)).not_nil![0].should eq (250 % 256).to_u8
  end

  it "updates an entry" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    codec = TrashPandaDB::Storage::RowCodec
    tree.insert(codec.encode_key(1_i64), Bytes[1])
    tree.update(codec.encode_key(1_i64), Bytes[42])
    tree.search(codec.encode_key(1_i64)).not_nil![0].should eq 42_u8
  end

  it "raises DuplicateKeyError on duplicate insert" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    codec = TrashPandaDB::Storage::RowCodec
    tree.insert(codec.encode_key(1_i64), Bytes[1])
    expect_raises(TrashPandaDB::Storage::DuplicateKeyError) do
      tree.insert(codec.encode_key(1_i64), Bytes[2])
    end
    # Original value must still be intact
    tree.search(codec.encode_key(1_i64)).not_nil![0].should eq 1_u8
  end

  # ── Overflow page tests ───────────────────────────────────────────────────

  it "stores and retrieves a value larger than one page (single overflow page)" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    key = "big_key".to_slice
    # PAGE_SIZE - 8 bytes: exactly fills one overflow page
    val = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE.to_i - 8, 0xAB_u8)
    tree.insert(key, val)
    result = tree.search(key).not_nil!
    result.size.should eq val.size
    result.should eq val
  end

  it "stores and retrieves a value spanning multiple overflow pages" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    key = "huge_key".to_slice
    # ~3× page size — forces a 4-page overflow chain
    val = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE.to_i * 3, 0xCD_u8)
    tree.insert(key, val)
    result = tree.search(key).not_nil!
    result.size.should eq val.size
    result.should eq val
  end

  it "includes overflow values in scan" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    codec = TrashPandaDB::Storage::RowCodec
    small_val = Bytes[1, 2, 3]
    large_val = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE.to_i * 2, 0xEF_u8)
    tree.insert(codec.encode_key(1_i64), small_val)
    tree.insert(codec.encode_key(2_i64), large_val)
    seen = {} of Int64 => Bytes
    tree.scan { |k, v| seen[codec.decode_key(k)] = v }
    seen.size.should eq 2
    seen[1_i64].should eq small_val
    seen[2_i64].should eq large_val
  end

  it "deletes a key with an overflow value" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    key = "del_overflow".to_slice
    val = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE.to_i * 2, 0x11_u8)
    tree.insert(key, val)
    tree.delete(key)
    tree.search(key).should be_nil
  end

  it "updates a key with an overflow value (old chain freed, new value readable)" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    key = "upd_overflow".to_slice
    val1 = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE.to_i * 2, 0x22_u8)
    val2 = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE.to_i * 2, 0x33_u8)
    tree.insert(key, val1)
    tree.update(key, val2)
    result = tree.search(key).not_nil!
    result.should eq val2
  end

  it "handles a leaf split where the new cell is an overflow cell" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    codec = TrashPandaDB::Storage::RowCodec
    # Fill the leaf with small values first
    n = (TrashPandaDB::Storage::PAGE_SIZE.to_i // 20)
    n.times { |i| tree.insert(codec.encode_key(i.to_i64), Bytes.new(10, (i % 256).to_u8)) }
    # Now insert a large value that forces an overflow + split
    large_val = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE.to_i * 2, 0x55_u8)
    tree.insert(codec.encode_key(9999_i64), large_val)
    tree.search(codec.encode_key(9999_i64)).not_nil!.should eq large_val
    # All small values still readable
    n.times { |i| tree.search(codec.encode_key(i.to_i64)).should_not be_nil }
  end

  it "mixes inline and overflow values on the same leaf" do
    pager = make_pager
    root = TrashPandaDB::Storage::BTree.create(pager)
    tree = TrashPandaDB::Storage::BTree.new(pager, root)
    codec = TrashPandaDB::Storage::RowCodec
    small = Bytes[9, 9, 9]
    large = Bytes.new(TrashPandaDB::Storage::PAGE_SIZE.to_i * 2, 0x77_u8)
    tree.insert(codec.encode_key(1_i64), small)
    tree.insert(codec.encode_key(2_i64), large)
    tree.insert(codec.encode_key(3_i64), small)
    tree.search(codec.encode_key(1_i64)).not_nil!.should eq small
    tree.search(codec.encode_key(2_i64)).not_nil!.should eq large
    tree.search(codec.encode_key(3_i64)).not_nil!.should eq small
  end
end