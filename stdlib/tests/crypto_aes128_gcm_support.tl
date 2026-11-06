(import stdlib.crypto_aes128_gcm as gcm)
(import stdlib.crypto_secret as secret)
(import stdlib.byte_buf as buf)
(import stdlib.tests.crypto_aes_core_inline as aes-vectors)
(import stdlib.test)
(import stdlib.io)

;: Public hexadecimal fixture decoding reuses the AES test-only driver.
(define (hex [value : String]) : buf.ByteBuf
  (aes-vectors.public-hex value))

;: Import a pinned public KAT key into its move-only secret owner.
(define (key [value : String]) : gcm.GcmKey
  (match (gcm.new (aes-vectors.fixed-hex (secret.Secret16) value))
    [(GcmKeyOk owner) owner]
    [(GcmKeyErr _) (io.panic "GCM vector key")]))

;: Import an exact public KAT nonce.
(define (nonce [value : String]) : gcm.GcmNonce
  (let
    [data : buf.ByteBuf (hex value)]
    (match (gcm.nonce-from-bytes (buf.as-bytes (& data)))
      [(GcmNonceOk result) result]
      [(GcmNonceErr _) (io.panic "GCM vector nonce")])))

;: Import an exact public KAT tag.
(define (tag [value : String]) : gcm.GcmTag
  (let
    [data : buf.ByteBuf (hex value)]
    (match (gcm.tag-from-bytes (buf.as-bytes (& data)))
      [(GcmTagOk result) result]
      [(GcmTagErr _) (io.panic "GCM vector tag")])))

;: Public byte comparison, used only on published ciphertext/plaintext KATs.
(define (equal? [left : (& left buf.ByteBuf)] [right : (& right buf.ByteBuf)]) : bool
  (let
    [ok : bool (= (buf.len left) (buf.len right))]
    [i : i64 0]
    (while (< i (buf.len left))
      (when
        (!= (buf.get left i (cast 0 : u8)) (buf.get right i (cast 0 : u8)))
        (set! ok false))
      (set! i (+ i 1)))
    ok))

;: Run exact production seal/open paths on one official published vector.
(define (vector
  [decrypt-only : bool]
  [failure : bool]
  [key-hex : String]
  [iv-hex : String]
  [aad-hex : String]
  [pt-hex : String]
  [ct-hex : String]
  [tag-hex : String]) : unit
  (let
    [owner : gcm.GcmKey (key key-hex)]
    [iv : gcm.GcmNonce (nonce iv-hex)]
    [expected : gcm.GcmTag (tag tag-hex)]
    [aad : buf.ByteBuf (hex aad-hex)]
    [pt : buf.ByteBuf (hex pt-hex)]
    [ct : buf.ByteBuf (hex ct-hex)]
    (unless
      decrypt-only
      (match (gcm.seal
        (& owner)
        (& iv)
        (buf.as-bytes (& aad))
        (buf.as-bytes (& pt)))
        [(GcmSealOk sealed)
          (test.assert-true
            (equal? (& sealed.ciphertext) (& ct))
            "NIST ciphertext")
          (let
            [index : i64 0]
            (while (< index 16)
              (test.assert-true
                (=
                  (array-ref sealed.tag.octets index)
                  (array-ref expected.octets index))
                "NIST tag")
              (set! index (+ index 1))))]
        [(GcmSealErr _) (test.assert-true false "NIST encryption status")]))
    (let
      [_before : i64 (cfg test gcm.payload-blocks 0)]
      (match (gcm.open
        (& owner)
        (& iv)
        (buf.as-bytes (& aad))
        (buf.as-bytes (& ct))
        (& expected))
        [(GcmOpenOk actual)
          (test.assert-true (not failure) "NIST failing decrypt rejected")
          (test.assert-true (equal? (& actual) (& pt)) "NIST plaintext")]
        [(GcmOpenErr (GcmAuthentication))
          (test.assert-true failure "NIST successful decrypt")
          (cfg
            test
            (test.assert-i64-eq
              gcm.payload-blocks
              _before
              "no payload AES on bad tag")
            unit)]
        [(GcmOpenErr _) (test.assert-true false "NIST decrypt status")]))
    (gcm.close owner)))