(import stdlib.crypto_aes128_gcm as gcm)
(cfg test (import stdlib.crypto_ghash_core as ghash))
(import stdlib.crypto_secret as secret)
(import stdlib.crypto_aes_core as aes)
(import stdlib.tests.crypto_aes128_gcm_support as vectors)
(import stdlib.tests.crypto_aes_lifecycle_inline as lifecycle)
(import stdlib.byte_buf as buf)
(import stdlib.test)
(cfg compile-profile (import stdlib.profile))

;: Arithmetic tests exercise huge limits without allocation or AES calls.
(define (accepted? [aad : i64] [payload : i64]) : bool
  (match (gcm.validate-lengths aad payload)
    [(GcmOk) true]
    [_ false]))

(test
  gcm-lengths
  (begin
    (test.assert-true (accepted? 0 0) "empty")
    (test.assert-true
      (accepted? (- (gcm.a-max) 1) (- (gcm.p-max) 1))
      "below limits")
    (test.assert-true (accepted? (gcm.a-max) (gcm.p-max)) "exact NIST limits")
    (test.assert-true (not (accepted? (+ (gcm.a-max) 1) 0)) "AAD bit overflow")
    (test.assert-true
      (not (accepted? 0 (+ (gcm.p-max) 1)))
      "RFC 5116 off by one")
    (test.assert-true (not (accepted? -1 0)) "negative AAD")
    (test.assert-true (not (accepted? 0 -1)) "negative plaintext")
    (test.assert-true
      (not (accepted? 9223372036854775807 0))
      "signed maximum AAD")
    (test.assert-true
      (not (accepted? 0 9223372036854775807))
      "signed maximum payload")
    (test.assert-i64-eq
      (/ (+ (gcm.p-max) 15) 16)
      4294967294
      "last payload counter")
    (match (gcm.validate-combined-length (gcm.a-max) (gcm.c-max))
      [(GcmOk) unit]
      [_ (test.assert-true false "combined exact maximum")])
    (match (gcm.validate-combined-length 0 (+ (gcm.c-max) 1))
      [(GcmErr _) unit]
      [_ (test.assert-true false "combined maximum plus one")])
    (match (gcm.validate-combined-length 0 15)
      [(GcmErr _) unit]
      [_ (test.assert-true false "combined truncated tag")])
    (match (gcm.validate-combined-length 0 16)
      [(GcmOk) unit]
      [_ (test.assert-true false "combined empty payload")])))

;: Consumer admission belongs outside the generic RFC 5116 primitive.
(define (tls-admits? [length : i64] [records : i64]) : bool
  (and
    (>= length 1)
    (<= length 16385)
    (< records 16777216)
    (accepted? 5 length)))

(define (ssh-admits? [aad : i64] [length : i64]) : bool
  (and
    (= aad 4)
    (>= length 0)
    (<= length 4294967264)
    (= (% length 16) 0)
    (accepted? aad length)))

(test
  gcm-consumer-limits
  (begin
    (test.assert-true (tls-admits? 16385 16777215) "TLS final record")
    (test.assert-true (not (tls-admits? 16386 0)) "TLS size admission")
    (test.assert-true (not (tls-admits? 1 16777216)) "TLS key admission")
    (test.assert-true (ssh-admits? 4 4294967264) "SSH body maximum")
    (test.assert-true (not (ssh-admits? 4 4294967280)) "SSH next block")
    (test.assert-true (not (ssh-admits? 5 16)) "SSH AAD")
    (test.assert-true (not (ssh-admits? 4 17)) "SSH alignment")
    (test.assert-true
      (accepted? 5 16386)
      "generic primitive retains larger TLS payload")
    (test.assert-true
      (accepted? 7 4294967280)
      "generic primitive retains larger SSH payload")))

;: Reject a complete candidate and prove the payload pass was not reached.
(cfg
  test
  (define (rejected
    [key : (& key gcm.GcmKey)]
    [nonce : (& nonce gcm.GcmNonce)]
    [aad : (& aad bytes)]
    [ct : (& ct bytes)]
    [tag : (& tag gcm.GcmTag)]) : unit
    (let
      [before : i64 gcm.payload-blocks]
      (match (gcm.open key nonce aad ct tag)
        [(GcmOpenErr (GcmAuthentication)) unit]
        [_ (test.assert-true false "tampered candidate publishes no plaintext")])
      (test.assert-i64-eq
        gcm.payload-blocks
        before
        "bad tag skips all payload AES"))))

(test
  gcm-mutations-and-truncations
  (let
    [key : gcm.GcmKey (vectors.key "00000000000000000000000000000000")]
    [other : gcm.GcmKey (vectors.key "00000000000000000000000000000001")]
    [nonce : gcm.GcmNonce (vectors.nonce "000000000000000000000000")]
    [other-nonce : gcm.GcmNonce (vectors.nonce "000000000000000000000001")]
    [aad : buf.ByteBuf (vectors.hex "000102030405060708090a0b0c0d0e0f10")]
    [plain : buf.ByteBuf
      (vectors.hex
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122")]
    (match (gcm.seal
      (& key)
      (& nonce)
      (buf.as-bytes (& aad))
      (buf.as-bytes (& plain)))
      [(GcmSealOk sealed)
        (rejected
          (& other)
          (& nonce)
          (buf.as-bytes (& aad))
          (buf.as-bytes (& sealed.ciphertext))
          (& sealed.tag))
        (rejected
          (& key)
          (& other-nonce)
          (buf.as-bytes (& aad))
          (buf.as-bytes (& sealed.ciphertext))
          (& sealed.tag))
        (let
          [index : i64 0]
          (while (< index 16)
            (let
              [tag : gcm.GcmTag sealed.tag]
              (set!
                (array-ref tag.octets index)
                (bit-xor (array-ref tag.octets index) (cast 1 : u8)))
              (rejected
                (& key)
                (& nonce)
                (buf.as-bytes (& aad))
                (buf.as-bytes (& sealed.ciphertext))
                (& tag)))
            (set! index (+ index 1)))
          (set! index 0)
          (while (< index (buf.len (& sealed.ciphertext)))
            (rejected
              (& key)
              (& nonce)
              (buf.as-bytes (& aad))
              (buf.bytes-slice-view
                (buf.as-bytes (& sealed.ciphertext))
                0
                index)
              (& sealed.tag))
            (set! index (+ index 1)))
          (set! index 0)
          (while (< index (buf.len (& aad)))
            (rejected
              (& key)
              (& nonce)
              (buf.bytes-slice-view (buf.as-bytes (& aad)) 0 index)
              (buf.as-bytes (& sealed.ciphertext))
              (& sealed.tag))
            (set! index (+ index 1))))
        (let
          [old : u8 (buf.get (& aad) 8 (cast 0 : u8))]
          (set! aad (buf.set! aad 8 (bit-xor old (cast 1 : u8))))
          (rejected
            (& key)
            (& nonce)
            (buf.as-bytes (& aad))
            (buf.as-bytes (& sealed.ciphertext))
            (& sealed.tag))
          (set! aad (buf.set! aad 8 old)))
        (let
          [old : u8 (buf.get (& sealed.ciphertext) 16 (cast 0 : u8))]
          (set!
            sealed.ciphertext
            (buf.set! sealed.ciphertext 16 (bit-xor old (cast 1 : u8))))
          (rejected
            (& key)
            (& nonce)
            (buf.as-bytes (& aad))
            (buf.as-bytes (& sealed.ciphertext))
            (& sealed.tag)))]
      [_ (test.assert-true false "mutation setup")])
    (let
      [index : i64 0]
      [data : buf.ByteBuf (buf.with-capacity 20)]
      (while (< index 20)
        (match (gcm.nonce-from-bytes (buf.as-bytes (& data)))
          [(GcmNonceOk _) (test.assert-i64-eq index 12 "nonce exact length")]
          [_ (test.assert-true (!= index 12) "nonce rejects wrong lengths")])
        (match (gcm.tag-from-bytes (buf.as-bytes (& data)))
          [(GcmTagOk _) (test.assert-i64-eq index 16 "tag exact length")]
          [_ (test.assert-true (!= index 16) "tag rejects wrong lengths")])
        (set! data (buf.push data (cast 0 : u8)))
        (set! index (+ index 1))))
    (gcm.close key)
    (gcm.close other)))

;: Public polynomial oracle: multiply coefficient arrays, then reduce the
;: degree-254 polynomial. It is deliberately independent of the production
;: shift recurrence and is never used with non-public test material.
(define (oracle-multiply [x : (& x buf.ByteBuf)] [y : (& y buf.ByteBuf)]) : buf.ByteBuf
  (let
    [coeff : (Array u8 256) (make-array u8 256)]
    [i : i64 0]
    [output : buf.ByteBuf (buf.with-capacity 16)]
    (while (< i 128)
      (let
        [j : i64 0]
        (while (< j 128)
          (let
            [a : u8
              (bit-and
                (shr
                  (buf.get x (/ i 8) (cast 0 : u8))
                  (cast (- 7 (% i 8)) : u64))
                (cast 1 : u8))]
            [b : u8
              (bit-and
                (shr
                  (buf.get y (/ j 8) (cast 0 : u8))
                  (cast (- 7 (% j 8)) : u64))
                (cast 1 : u8))]
            (set!
              (array-ref coeff (+ i j))
              (bit-xor (array-ref coeff (+ i j)) (bit-and a b))))
          (set! j (+ j 1))))
      (set! i (+ i 1)))
    (set! i 254)
    (while (>= i 128)
      (let
        [bit : u8 (array-ref coeff i)]
        (set!
          (array-ref coeff (- i 128))
          (bit-xor (array-ref coeff (- i 128)) bit))
        (set!
          (array-ref coeff (- i 127))
          (bit-xor (array-ref coeff (- i 127)) bit))
        (set!
          (array-ref coeff (- i 126))
          (bit-xor (array-ref coeff (- i 126)) bit))
        (set!
          (array-ref coeff (- i 121))
          (bit-xor (array-ref coeff (- i 121)) bit)))
      (set! i (- i 1)))
    (set! i 0)
    (while (< i 16)
      (let
        [value : u8 (cast 0 : u8)]
        [j : i64 0]
        (while (< j 8)
          (set!
            value
            (bit-or (shl value (cast 1 : u64)) (array-ref coeff (+ (* i 8) j))))
          (set! j (+ j 1)))
        (set! output (buf.push output value)))
      (set! i (+ i 1)))
    output))

;: Direct region boundaries compare against separately constructed public
;: coefficient-oracle blocks, including the independent AAD/C padding.
(cfg
  test
  (define (component [aad-length : i64] [ct-length : i64]) : unit
    (let
      [h : buf.ByteBuf (vectors.hex "66e94bd4ef8a2c3b884cfa59ca342b2e")]
      [input : buf.ByteBuf
        (vectors.hex
          "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00")]
      [state : buf.ByteBuf (vectors.hex "00000000000000000000000000000000")]
      [actual : (Array u64 2) (make-array u64 2)]
      [phase : i64 0]
      [before : i64 ghash.multiply-steps]
      (while (< phase 3)
        (let
          [length : i64
            (if (= phase 0)
              aad-length
              (if (= phase 1)
                ct-length
                16))]
          [offset : i64 0]
          (while (< offset length)
            (let
              [block : buf.ByteBuf (buf.with-capacity 16)]
              [index : i64 0]
              (while (< index 16)
                (let
                  [value : u8 (cast 0 : u8)]
                  (if (= phase 2)
                    (set!
                      value
                      (cast
                        (shr
                          (cast
                            (if (< index 8)
                              (* aad-length 8)
                              (* ct-length 8))
                            : u64)
                          (cast (- 56 (* (% index 8) 8)) : u64))
                        : u8))
                    (when
                      (< (+ offset index) length)
                      (set!
                        value
                        (buf.get (& input) (+ offset index) (cast 0 : u8)))))
                  (set!
                    block
                    (buf.push
                      block
                      (bit-xor value (buf.get (& state) index (cast 0 : u8))))))
                (set! index (+ index 1)))
              (set! state (oracle-multiply (& block) (& h))))
            (set! offset (+ offset 16))))
        (set! phase (+ phase 1)))
      (unsafe
        (ghash.authenticate!
          (buf.bytes-data (buf.as-bytes (& h)))
          (buf.bytes-data (buf.as-bytes (& input)))
          aad-length
          (buf.bytes-data (buf.as-bytes (& input)))
          ct-length
          (ptr-cast (ptr-addr-of actual) : (MutPtr u8))))
      (test.assert-true
        (=
          (unsafe
            (secret.difference-bits
              (ptr-cast (ptr-addr-of actual) : (Ptr u8))
              (buf.bytes-data (buf.as-bytes (& state)))
              16))
          (cast 0 : u64))
        "GHASH coefficient oracle including padding and lengths")
      (test.assert-i64-eq
        (- ghash.multiply-steps before)
        (* 128 (+ (+ (/ (+ aad-length 15) 16) (/ (+ ct-length 15) 16)) 1))
        "exact multiplication steps")
      (unsafe
        (secret.wipe-words! (ptr-cast (ptr-addr-of actual) : (MutPtr u64)) 2)))))

(test
  gcm-ghash-components
  (let
    [sizes : (Array i64 6) (array 0 1 15 16 17 32)]
    [a : i64 0]
    (while (< a 6)
      (let
        [c : i64 0]
        (while (< c 6)
          (component (array-ref sizes a) (array-ref sizes c))
          (set! c (+ c 1))))
      (set! a (+ a 1)))))

(test
  gcm-counter-boundaries
  (let
    [nonce : gcm.GcmNonce (vectors.nonce "000102030405060708090a0b")]
    [scratch : (Array u64 2) (make-array u64 2)]
    [data : (MutPtr u8)
      (unsafe
        (ptr-cast (ptr-addr-of scratch) : (MutPtr u8)))]
    (unsafe
      (gcm.counter! (& nonce) (cast 1 : u32) data))
    (let
      [expected : buf.ByteBuf (vectors.hex "000102030405060708090a0b00000001")]
      (test.assert-true
        (=
          (unsafe
            (secret.difference-bits
              (ptr-cast data : (Ptr u8))
              (buf.bytes-data (buf.as-bytes (& expected)))
              16))
          (cast 0 : u64))
        "J0 exact"))
    (unsafe
      (gcm.counter! (& nonce) (cast 4294967295 : u32) data))
    (let
      [expected : buf.ByteBuf (vectors.hex "000102030405060708090a0bffffffff")]
      (test.assert-true
        (=
          (unsafe
            (secret.difference-bits
              (ptr-cast data : (Ptr u8))
              (buf.bytes-data (buf.as-bytes (& expected)))
              16))
          (cast 0 : u64))
        "last inc32 preserves nonce"))
    (unsafe
      (secret.wipe-words! (ptr-cast data : (MutPtr u64)) 2))))

(test
  gcm-key-lifecycle
  (let
    [raw : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [raw-storage : (MutPtr secret.SecretStorage) raw.handle.storage]
    (match (gcm.new raw)
      [(GcmKeyOk key)
        (test.assert-true
          (lifecycle.wiped? raw-storage 16)
          "raw key wiped immediately")
        (let
          [schedule : (MutPtr secret.SecretStorage)
            key.schedule.expanded.handle.storage]
          [h : (MutPtr secret.SecretStorage) key.h.handle.storage]
          (with ([owner key gcm.close]) unit)
          (test.assert-true
            (lifecycle.wiped? schedule 176)
            "nested schedule wiped")
          (test.assert-true (lifecycle.wiped? h 16) "nested H wiped"))]
      [_ (test.assert-true false "key lifecycle")])
    (let
      [wrong : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
      [storage : (MutPtr secret.SecretStorage) wrong.handle.storage]
      (match (gcm.new wrong)
        [(GcmKeyErr _) unit]
        [(GcmKeyOk key)
          (gcm.close key)
          (test.assert-true false "wrong key length")])
      (test.assert-true
        (lifecycle.wiped? storage 32)
        "rejected consumed key wiped"))))

;: A stale nominal key cannot consume the original allocation's generation.
(test
  gcm-stale-and-malformed-key
  (let
    [raw : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [stale : secret.SecretFixed
      (secret.SecretFixed
        (secret.SecretHandle raw.handle.storage (+ raw.handle.generation 1)))]
    (match (gcm.new stale)
      [(GcmKeyErr (GcmAes (AesSecret (SecretClosed)))) unit]
      [(GcmKeyErr _) (test.assert-true false "stale key status")]
      [(GcmKeyOk key)
        (gcm.close key)
        (test.assert-true false "stale key accepted")])
    (test.assert-i64-eq
      (secret.fixed-length (& raw))
      16
      "live generation preserved")
    (secret.close-fixed raw)
    (match (aes.new-128 (secret.fixed-zero (secret.Secret16)))
      [(Aes128Ok schedule)
        (let
          [key : gcm.GcmKey
            (gcm.GcmKey schedule (secret.fixed-zero (secret.Secret32)))]
          [nonce : gcm.GcmNonce (vectors.nonce "000000000000000000000000")]
          [empty : buf.ByteBuf (buf.new)]
          (match (gcm.seal
            (& key)
            (& nonce)
            (buf.as-bytes (& empty))
            (buf.as-bytes (& empty)))
            [(GcmSealErr (GcmSecret (SecretLengthMismatch 16 32))) unit]
            [_ (test.assert-true false "malformed H rejected before use")])
          (gcm.close key))]
      [_ (test.assert-true false "malformed context setup")])))

;: Paired first/middle/last secret bit changes traverse identical AES work
;: and exactly the same number of GHASH bit steps at equal public lengths.
(cfg
  test
  (define (paired-work [bit : i64]) : (Tuple i64 i64)
    (let
      [raw : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
      (when
        (>= bit 0)
        (match (unsafe
          (secret.fixed-write-pointer (&mut raw) (/ bit 8) 1))
          [(SecretWriteOk destination)
            (unsafe
              (ptr-write!
                destination
                (shl (cast 1 : u8) (cast (% bit 8) : u64))))]
          [_ (test.assert-true false "paired key construction")]))
      (match (gcm.new raw)
        [(GcmKeyOk key)
          (let
            [nonce : gcm.GcmNonce (vectors.nonce "000000000000000000000000")]
            [plain : buf.ByteBuf
              (vectors.hex "000102030405060708090a0b0c0d0e0f10")]
            [aes-before : i64 aes.source-work]
            [ghash-before : i64 ghash.multiply-steps]
            (match (gcm.seal
              (& key)
              (& nonce)
              (buf.as-bytes (& plain))
              (buf.as-bytes (& plain)))
              [(GcmSealOk _) unit]
              [_ (test.assert-true false "paired seal")])
            (gcm.close key)
            (tuple
              (- aes.source-work aes-before)
              (- ghash.multiply-steps ghash-before)))]
        [_
          (test.assert-true false "paired context")
          (tuple 0 0)]))))

(test
  gcm-paired-secret-work
  (let
    [baseline : (Tuple i64 i64) (paired-work -1)]
    [bits : (Array i64 3) (array 0 64 127)]
    [index : i64 0]
    (while (< index 3)
      (let
        [actual : (Tuple i64 i64) (paired-work (array-ref bits index))]
        (test.assert-i64-eq
          (tuple-ref actual 0)
          (tuple-ref baseline 0)
          "paired AES work")
        (test.assert-i64-eq
          (tuple-ref actual 1)
          (tuple-ref baseline 1)
          "paired GHASH work"))
      (set! index (+ index 1)))))

;: Allocation grows only by the fresh output's capacity, independently of
;: the number of inner blocks. Both paths retain only fixed scratch owners.
(cfg
  compile-profile
  (define (allocated [length : i64] [decrypt : bool]) : i64
    (let
      [key : gcm.GcmKey (vectors.key "00000000000000000000000000000000")]
      [nonce : gcm.GcmNonce (vectors.nonce "000000000000000000000000")]
      [plain : buf.ByteBuf (buf.with-capacity length)]
      (set! plain.len length)
      (match (gcm.seal
        (& key)
        (& nonce)
        (buf.as-bytes (& plain))
        (buf.as-bytes (& plain)))
        [(GcmSealOk sealed)
          (let
            [before : i64 (profile.alloc-total)]
            (if decrypt
              (match (gcm.open
                (& key)
                (& nonce)
                (buf.as-bytes (& plain))
                (buf.as-bytes (& sealed.ciphertext))
                (& sealed.tag))
                [(GcmOpenOk _) unit]
                [_ (test.assert-true false "allocation open")])
              (match (gcm.seal
                (& key)
                (& nonce)
                (buf.as-bytes (& plain))
                (buf.as-bytes (& plain)))
                [(GcmSealOk _) unit]
                [_ (test.assert-true false "allocation seal")]))
            (gcm.close key)
            (- (profile.alloc-total) before))]
        [_
          (gcm.close key)
          (test.assert-true false "allocation setup")
          0]))))

(cfg
  compile-profile
  (test
    gcm-inner-loops-no-allocation
    (begin
      (test.assert-i64-eq
        (- (allocated 16384 false) (allocated 16 false))
        16368
        "seal only output growth")
      (test.assert-i64-eq
        (- (allocated 16384 true) (allocated 16 true))
        16368
        "open only output growth"))))