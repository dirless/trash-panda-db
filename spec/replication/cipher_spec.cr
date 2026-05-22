require "../spec_helper"
require "../../src/trash_panda_db/replication/cipher"

include TrashPandaDB::Replication

describe Cipher do
  it "round-trips plaintext" do
    key = Random::Secure.random_bytes(Cipher::KEY_SIZE)
    c = Cipher.new(key)
    plain = "hello, raft transport encryption!".to_slice
    String.new(c.decrypt(c.encrypt(plain)).not_nil!).should eq "hello, raft transport encryption!"
  end

  it "produces a fresh nonce each call (ciphertexts differ)" do
    key = Random::Secure.random_bytes(Cipher::KEY_SIZE)
    c = Cipher.new(key)
    plain = "same message".to_slice
    c.encrypt(plain).should_not eq c.encrypt(plain)
  end

  it "output length is plaintext + nonce + tag" do
    key = Random::Secure.random_bytes(Cipher::KEY_SIZE)
    c = Cipher.new(key)
    plain = "test".to_slice
    c.encrypt(plain).size.should eq plain.size + Cipher::NONCE_SIZE + Cipher::TAG_SIZE
  end

  it "returns nil when the tag is tampered" do
    key = Random::Secure.random_bytes(Cipher::KEY_SIZE)
    c = Cipher.new(key)
    enc = c.encrypt("secret".to_slice)
    enc[-1] ^= 0xff
    c.decrypt(enc).should be_nil
  end

  it "returns nil when the ciphertext body is tampered" do
    key = Random::Secure.random_bytes(Cipher::KEY_SIZE)
    c = Cipher.new(key)
    enc = c.encrypt("secret".to_slice)
    enc[Cipher::NONCE_SIZE] ^= 0x01
    c.decrypt(enc).should be_nil
  end

  it "returns nil for data shorter than nonce + tag" do
    key = Random::Secure.random_bytes(Cipher::KEY_SIZE)
    c = Cipher.new(key)
    c.decrypt(Bytes.new(Cipher::NONCE_SIZE + Cipher::TAG_SIZE - 1)).should be_nil
  end

  it "returns nil when decrypted with the wrong key" do
    key1 = Random::Secure.random_bytes(Cipher::KEY_SIZE)
    key2 = Random::Secure.random_bytes(Cipher::KEY_SIZE)
    enc = Cipher.new(key1).encrypt("secret".to_slice)
    Cipher.new(key2).decrypt(enc).should be_nil
  end

  it "accepts a 64-char hex key via from_hex" do
    hex = "deadbeef" * 8
    c = Cipher.from_hex(hex)
    plain = "hex key test".to_slice
    String.new(c.decrypt(c.encrypt(plain)).not_nil!).should eq "hex key test"
  end

  it "raises on hex key with wrong length" do
    expect_raises(ArgumentError) { Cipher.from_hex("aa" * 31) }
    expect_raises(ArgumentError) { Cipher.from_hex("aa" * 33) }
  end

  it "raises on key with wrong byte length" do
    expect_raises(ArgumentError) { Cipher.new(Bytes.new(16)) }
  end

  it "round-trips an empty message" do
    key = Random::Secure.random_bytes(Cipher::KEY_SIZE)
    c = Cipher.new(key)
    plain = Bytes.empty
    c.decrypt(c.encrypt(plain)).not_nil!.size.should eq 0
  end
end
