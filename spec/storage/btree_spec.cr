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
end