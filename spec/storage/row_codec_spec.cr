require "../spec_helper"

describe TrashPandaDB::Storage::RowCodec do
  it "round-trips all value types" do
    row : Array(TrashPandaDB::SQL::Value) = [
      nil, true, false, 42_i64, 3.14_f64, "hello", Bytes[1, 2, 3]
    ]
    decoded = TrashPandaDB::Storage::RowCodec.decode(TrashPandaDB::Storage::RowCodec.encode(row))
    decoded.size.should eq row.size
    decoded[0].should be_nil
    decoded[1].should eq true
    decoded[2].should eq false
    decoded[3].should eq 42_i64
    decoded[4].should eq 3.14_f64
    decoded[5].should eq "hello"
    decoded[6].as(Bytes).to_a.should eq [1, 2, 3]
  end

  it "round-trips all-null row" do
    row = [nil, nil, nil] of TrashPandaDB::SQL::Value
    decoded = TrashPandaDB::Storage::RowCodec.decode(TrashPandaDB::Storage::RowCodec.encode(row))
    decoded.all?(&.nil?).should be_true
  end

  it "encodes rowid key in big-endian sort order" do
    k1 = TrashPandaDB::Storage::RowCodec.encode_key(1_i64)
    k2 = TrashPandaDB::Storage::RowCodec.encode_key(2_i64)
    k100 = TrashPandaDB::Storage::RowCodec.encode_key(100_i64)
    (k1 <=> k2).should be < 0
    (k2 <=> k100).should be < 0
  end

  it "decode_key is inverse of encode_key" do
    [-1_i64, 0_i64, 1_i64, Int64::MAX, Int64::MIN].each do |v|
      TrashPandaDB::Storage::RowCodec.decode_key(TrashPandaDB::Storage::RowCodec.encode_key(v)).should eq v
    end
  end
end