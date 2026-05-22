require "openssl"
require "base64"
require "random/secure"

lib LibCrypto
  EVP_CTRL_AEAD_SET_IVLEN = 0x9
  EVP_CTRL_AEAD_GET_TAG   = 0x10
  EVP_CTRL_AEAD_SET_TAG   = 0x11

  fun evp_cipher_ctx_ctrl = EVP_CIPHER_CTX_ctrl(ctx : EVP_CIPHER_CTX, type : Int32, arg : Int32, ptr : Void*) : Int32
end

module TrashPandaDB::Replication
  # ChaCha20-Poly1305 AEAD cipher for Raft RPC transport encryption.
  # Each message is encrypted with a fresh random 12-byte nonce.
  # Wire layout: nonce[12] || ciphertext || tag[16]
  struct Cipher
    TAG_SIZE   = 16
    NONCE_SIZE = 12
    KEY_SIZE   = 32

    def self.from_hex(hex : String) : Cipher
      raise ArgumentError.new("TPDB_REPLICATION_KEY must be 64 hex chars (32 bytes), got #{hex.size} chars") unless hex.size == 64
      new(hex.hexbytes)
    end

    def initialize(@key : Bytes)
      raise ArgumentError.new("cipher key must be #{KEY_SIZE} bytes, got #{@key.size}") unless @key.size == KEY_SIZE
    end

    def encrypt(plaintext : Bytes) : Bytes
      nonce = Random::Secure.random_bytes(NONCE_SIZE)
      ctx = LibCrypto.evp_cipher_ctx_new
      begin
        ct = LibCrypto.evp_get_cipherbyname("chacha20-poly1305")
        LibCrypto.evp_cipherinit_ex(ctx, ct, nil, nil, nil, 1)
        LibCrypto.evp_cipher_ctx_ctrl(ctx, LibCrypto::EVP_CTRL_AEAD_SET_IVLEN, NONCE_SIZE, nil)
        LibCrypto.evp_cipherinit_ex(ctx, nil, nil, @key.to_unsafe, nonce.to_unsafe, 1)
        LibCrypto.evp_cipher_ctx_set_padding(ctx, 0)

        outbuf = Bytes.new(plaintext.size)
        outlen = plaintext.size
        LibCrypto.evp_cipherupdate(ctx, outbuf.to_unsafe, pointerof(outlen), plaintext.to_unsafe, plaintext.size)

        scratch = Bytes.new(1)
        scratch_len = 0
        LibCrypto.evp_cipherfinal_ex(ctx, scratch.to_unsafe, pointerof(scratch_len))

        tag = Bytes.new(TAG_SIZE)
        LibCrypto.evp_cipher_ctx_ctrl(ctx, LibCrypto::EVP_CTRL_AEAD_GET_TAG, TAG_SIZE, tag.to_unsafe.as(Void*))

        result = Bytes.new(NONCE_SIZE + outlen + TAG_SIZE)
        nonce.copy_to(result[0, NONCE_SIZE])
        outbuf[0, outlen].copy_to(result[NONCE_SIZE, outlen])
        tag.copy_to(result[NONCE_SIZE + outlen, TAG_SIZE])
        result
      ensure
        LibCrypto.evp_cipher_ctx_free(ctx)
      end
    end

    # Returns decrypted plaintext, or nil if the tag does not verify.
    def decrypt(data : Bytes) : Bytes?
      return nil if data.size < NONCE_SIZE + TAG_SIZE

      nonce          = data[0, NONCE_SIZE]
      ciphertext_len = data.size - NONCE_SIZE - TAG_SIZE
      ciphertext     = data[NONCE_SIZE, ciphertext_len]
      tag            = data[NONCE_SIZE + ciphertext_len, TAG_SIZE].dup

      ctx = LibCrypto.evp_cipher_ctx_new
      begin
        ct = LibCrypto.evp_get_cipherbyname("chacha20-poly1305")
        LibCrypto.evp_cipherinit_ex(ctx, ct, nil, nil, nil, 0)
        LibCrypto.evp_cipher_ctx_ctrl(ctx, LibCrypto::EVP_CTRL_AEAD_SET_IVLEN, NONCE_SIZE, nil)
        LibCrypto.evp_cipherinit_ex(ctx, nil, nil, @key.to_unsafe, nonce.to_unsafe, 0)
        LibCrypto.evp_cipher_ctx_set_padding(ctx, 0)

        outbuf = Bytes.new(ciphertext_len)
        outlen = ciphertext_len
        LibCrypto.evp_cipherupdate(ctx, outbuf.to_unsafe, pointerof(outlen), ciphertext.to_unsafe, ciphertext.size)

        LibCrypto.evp_cipher_ctx_ctrl(ctx, LibCrypto::EVP_CTRL_AEAD_SET_TAG, TAG_SIZE, tag.to_unsafe.as(Void*))
        scratch = Bytes.new(1)
        scratch_len = 0
        ret = LibCrypto.evp_cipherfinal_ex(ctx, scratch.to_unsafe, pointerof(scratch_len))
        return nil unless ret == 1

        outbuf[0, outlen]
      rescue
        nil
      ensure
        LibCrypto.evp_cipher_ctx_free(ctx)
      end
    end
  end
end
