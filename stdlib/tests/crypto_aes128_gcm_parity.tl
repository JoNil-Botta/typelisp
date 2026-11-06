; Pure full-operation target-parity witness; the complete KAT/assertion driver
; intentionally includes platform-specific assertion I/O and is run separately.
(import stdlib.crypto_aes128_gcm as gcm)
(import stdlib.crypto_secret as secret)
(import stdlib.byte_buf as buf)

(define (main) : i64
  (let
    [nonce : gcm.GcmNonce (gcm.GcmNonce (make-array u8 12))]
    [plain : buf.ByteBuf (buf.with-capacity 16)]
    [expected : (Array u8 16)
      (array 3 136 218 206 96 182 163 146 243 40 194 185 113 178 254 120)]
    [tag : gcm.GcmTag
      (gcm.GcmTag
        (array 171 110 71 212 44 236 19 189 245 58 103 178 18 87 189 223))]
    (set! plain.len 16)
    (match (gcm.new (secret.fixed-zero (secret.Secret16)))
      [(GcmKeyErr _) 1]
      [(GcmKeyOk key)
        (with
          ([owner key gcm.close])
          (match (gcm.seal
            (& owner)
            (& nonce)
            (buf.str-as-bytes "")
            (buf.as-bytes (& plain)))
            [(GcmSealErr _) 2]
            [(GcmSealOk sealed)
              (let
                [index : i64 0]
                (unless (= (buf.len (& sealed.ciphertext)) 16) (return 3))
                (while (< index 16)
                  (unless
                    (and
                      (=
                        (buf.get (& sealed.ciphertext) index (cast 0 : u8))
                        (array-ref expected index))
                      (=
                        (array-ref sealed.tag.octets index)
                        (array-ref tag.octets index)))
                    (return 4))
                  (set! index (+ index 1))))
              (match (gcm.open
                (& owner)
                (& nonce)
                (buf.str-as-bytes "")
                (buf.as-bytes (& sealed.ciphertext))
                (& tag))
                [(GcmOpenErr _) (return 5)]
                [(GcmOpenOk output)
                  (unless (= (buf.len (& output)) 16) (return 6))
                  (let
                    [index : i64 0]
                    (while (< index 16)
                      (unless
                        (=
                          (buf.get (& output) index (cast 1 : u8))
                          (cast 0 : u8))
                        (return 7))
                      (set! index (+ index 1))))])
              (set!
                (array-ref tag.octets 0)
                (bit-xor (array-ref tag.octets 0) (cast 1 : u8)))
              (match (gcm.open
                (& owner)
                (& nonce)
                (buf.str-as-bytes "")
                (buf.as-bytes (& sealed.ciphertext))
                (& tag))
                [(GcmOpenErr (GcmAuthentication)) 42]
                [_ 8])]))])))