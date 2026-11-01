(import stdlib.crypto_aes_core as aes)
(import stdlib.crypto_secret as secret)
(import stdlib.tests.crypto_aes_core_inline as vectors)
(import stdlib.test)
(import stdlib.profile)
(import stdlib.comptime)

;: A wipe assertion returns only a boolean; it never exports secret bytes.
(define (wiped? [storage : (MutPtr secret.SecretStorage)] [capacity : i64]) : bool
  (let
    [zero : bool true]
    [index : i64 0]
    [data : (Ptr u8)
      (unsafe
        (ptr-cast (secret.storage-data storage) : (Ptr u8)))]
    (while (< index capacity)
      (when
        (!=
          (unsafe
            (ptr-read (ptr-offset data index)))
          (cast 0 : u8))
        (set! zero false))
      (set! index (+ index 1)))
    (and
      zero
      (=
        (unsafe
          (secret.storage-header storage)).state
        (secret.state-closed))
      (=
        (unsafe
          (secret.storage-header storage)).length
        (cast 0 : u64)))))

(test
  aes-constructor-stale-generation
  (let
    [owner : secret.SecretFixed
      (vectors.fixed-hex (secret.Secret16) "000102030405060708090a0b0c0d0e0f")]
    [stale : secret.SecretFixed
      (secret.SecretFixed
        (secret.SecretHandle owner.handle.storage (+ owner.handle.generation 1)))]
    [before : i64 (profile.alloc-total)]
    (match (aes.new-128 stale)
      [(Aes128Err (AesSecret (SecretClosed))) unit]
      [(Aes128Err _) (test.assert-true false "stale key error")]
      [(Aes128Ok schedule)
        (aes.close-128 schedule)
        (test.assert-true false "stale key accepted")])
    (test.assert-i64-eq
      (profile.alloc-total)
      before
      "stale key allocates nothing")
    (test.assert-i64-eq
      (secret.fixed-length (& owner))
      16
      "stale key cannot close another generation")
    (secret.close-fixed owner)))

(test
  aes-constructor-failure-wipes
  (let
    [key : secret.SecretFixed
      (vectors.fixed-hex
        (secret.Secret32)
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")]
    [storage : (MutPtr secret.SecretStorage) key.handle.storage]
    [before : i64 (profile.alloc-total)]
    (match (aes.new-128 key)
      [(Aes128Err (AesSecret (SecretLengthMismatch 16 32))) unit]
      [(Aes128Err _) (test.assert-true false "wrong length error")]
      [(Aes128Ok schedule)
        (aes.close-128 schedule)
        (test.assert-true false "wide key accepted")])
    (test.assert-i64-eq
      (profile.alloc-total)
      before
      "bad length allocates nothing")
    (test.assert-true (wiped? storage 32) "consumed rejected key wipes")))

;: Exercise consuming-key wipe, complete schedule cleanup and repeated blocks.
(define (lifecycle [wide : bool]) : unit
  (let
    [key : secret.SecretFixed
      (secret.fixed-zero
        (if wide
          (secret.Secret32)
          (secret.Secret16)))]
    [key-storage : (MutPtr secret.SecretStorage) key.handle.storage]
    [source : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [destination : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [before : i64 (profile.alloc-total)]
    [schedule-storage : (MutPtr secret.SecretStorage)
      (ptr-null : (MutPtr secret.SecretStorage))]
    (if wide
      (match (aes.new-256 key)
        [(Aes256Ok schedule)
          (set! schedule-storage schedule.expanded.handle.storage)
          (test.assert-i64-eq
            (- (profile.alloc-total) before)
            272
            "one exact AES-256 schedule allocation")
          (test.assert-true
            (wiped? key-storage 32)
            "raw AES-256 key closes immediately")
          (let
            [block-before : i64 (profile.alloc-total)]
            [index : i64 0]
            (while (< index 8)
              (match (aes.encrypt-256!
                (& schedule)
                (& source)
                (&mut destination))
                [(AesOk) unit]
                [_ (test.assert-true false "repeated AES-256")])
              (set! index (+ index 1)))
            (test.assert-i64-eq
              (profile.alloc-total)
              block-before
              "AES-256 blocks allocate nothing"))
          (aes.close-256 schedule)]
        [_ (test.assert-true false "AES-256 construction")])
      (match (aes.new-128 key)
        [(Aes128Ok schedule)
          (set! schedule-storage schedule.expanded.handle.storage)
          (test.assert-i64-eq
            (- (profile.alloc-total) before)
            208
            "one exact AES-128 schedule allocation")
          (test.assert-true
            (wiped? key-storage 16)
            "raw AES-128 key closes immediately")
          (let
            [block-before : i64 (profile.alloc-total)]
            [index : i64 0]
            (while (< index 8)
              (match (aes.encrypt-128!
                (& schedule)
                (& source)
                (&mut destination))
                [(AesOk) unit]
                [_ (test.assert-true false "repeated AES-128")])
              (set! index (+ index 1)))
            (test.assert-i64-eq
              (profile.alloc-total)
              block-before
              "AES-128 blocks allocate nothing"))
          (aes.close-128 schedule)]
        [_ (test.assert-true false "AES-128 construction")]))
    (test.assert-true
      (wiped?
        schedule-storage
        (if wide
          240
          176))
      "entire expanded schedule closes")
    (secret.storage-close
      (secret.SecretHandle
        schedule-storage
        (cast
          (unsafe
            (secret.storage-header schedule-storage)).generation
          : i64)))
    (test.assert-true
      (wiped?
        schedule-storage
        (if wide
          240
          176))
      "second storage close is inert")
    (secret.close-fixed source)
    (secret.close-fixed destination)))

(test
  aes-typed-lifecycles-and-allocation
  (begin
    (lifecycle false)
    (lifecycle true)))

;: Pin exact fixed-length boundaries by corrupting only public fixture metadata.
;: No rejected request may publish even one destination byte.
(define (length-boundaries [wide : bool]) : unit
  (let
    [key : secret.SecretFixed
      (secret.fixed-zero
        (if wide
          (secret.Secret32)
          (secret.Secret16)))]
    [source : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [destination : secret.SecretFixed
      (vectors.fixed-hex (secret.Secret16) "0102030405060708090a0b0c0d0e0f10")]
    [expected : secret.SecretFixed
      (vectors.fixed-hex (secret.Secret16) "0102030405060708090a0b0c0d0e0f10")]
    [lengths : (Array i64 8) (array -1 0 1 15 17 31 32 65536)]
    (if wide
      (match (aes.new-256 key)
        [(Aes256Ok schedule)
          (let
            [index : i64 0]
            (while (< index 8)
              (unsafe
                (secret.storage-set-length!
                  source.handle.storage
                  (array-ref lengths index)))
              (match (aes.encrypt-256!
                (& schedule)
                (& source)
                (&mut destination))
                [(AesErr _) unit]
                [_
                  (test.assert-true false "bad AES-256 source length accepted")])
              (test.assert-true
                (vectors.equal-fixed? (& destination) (& expected))
                "failure leaves destination unchanged")
              (set! index (+ index 1))))
          (aes.close-256 schedule)]
        [_ (test.assert-true false "schedule")])
      (match (aes.new-128 key)
        [(Aes128Ok schedule)
          (let
            [index : i64 0]
            (while (< index 8)
              (unsafe
                (secret.storage-set-length!
                  source.handle.storage
                  (array-ref lengths index)))
              (match (aes.encrypt-128!
                (& schedule)
                (& source)
                (&mut destination))
                [(AesErr _) unit]
                [_
                  (test.assert-true false "bad AES-128 source length accepted")])
              (test.assert-true
                (vectors.equal-fixed? (& destination) (& expected))
                "failure leaves destination unchanged")
              (set! index (+ index 1))))
          (aes.close-128 schedule)]
        [_ (test.assert-true false "schedule")]))
    (unsafe
      (secret.storage-set-length! source.handle.storage 16))
    (secret.close-fixed source)
    (secret.close-fixed destination)
    (secret.close-fixed expected)))

(test
  aes-exact-block-boundaries
  (begin
    (length-boundaries false)
    (length-boundaries true)))

(test
  aes-exact-alias-and-stale-preflight
  (let
    [source : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [destination : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [stale : secret.SecretFixed
      (secret.SecretFixed
        (secret.SecretHandle
          source.handle.storage
          (+ source.handle.generation 1)))]
    [alias : secret.SecretFixed (secret.SecretFixed source.handle)]
    (match (aes.new-128 (secret.fixed-zero (secret.Secret16)))
      [(Aes128Ok schedule)
        (match (aes.encrypt-128! (& schedule) (& source) (&mut alias))
          [(AesErr (AesOverlap)) unit]
          [_ (test.assert-true false "exact alias accepted")])
        (match (aes.encrypt-128! (& schedule) (& stale) (&mut destination))
          [(AesErr (AesSecret (SecretClosed))) unit]
          [_ (test.assert-true false "stale source accepted")])
        (test.assert-true
          (vectors.equal-fixed? (& source) (& destination))
          "rejected calls leave bytes unchanged")
        (aes.close-128 schedule)]
      [_ (test.assert-true false "schedule")])
    (secret.close-fixed source)
    (secret.close-fixed destination)
    (secret.close-fixed stale)
    (secret.close-fixed alias)))

(test
  aes-partial-overlap-preflight
  (let
    [storage : (MutPtr secret.SecretStorage)
      (unsafe
        (secret.storage-new 64 0))]
    [second : (MutPtr secret.SecretStorage)
      (unsafe
        (ptr-cast
          (ptr-offset (ptr-cast storage : (MutPtr u64)) 1)
          : (MutPtr secret.SecretStorage)))]
    (unsafe
      (ptr-write!
        storage
        (secret.SecretStorage
          (cast 0 : u64)
          (cast 0 : u64)
          (cast 16 : u64)
          (cast 16 : u64))))
    (unsafe
      (ptr-write!
        (ptr-cast (secret.storage-data storage) : (MutPtr u64))
        (cast 16 : u64)))
    (let
      [source : secret.SecretFixed
        (secret.SecretFixed (secret.SecretHandle storage 0))]
      [destination : secret.SecretFixed
        (secret.SecretFixed (secret.SecretHandle second 16))]
      [expected : secret.SecretFixed
        (vectors.fixed-hex (secret.Secret16) "10000000000000000000000000000000")]
      (match (aes.new-128 (secret.fixed-zero (secret.Secret16)))
        [(Aes128Ok schedule)
          (match (aes.encrypt-128! (& schedule) (& source) (&mut destination))
            [(AesErr (AesOverlap)) unit]
            [_ (test.assert-true false "partial overlap accepted")])
          (test.assert-true
            (vectors.equal-fixed? (& source) (& expected))
            "partial overlap rejected before mutation")
          (aes.close-128 schedule)]
        [_ (test.assert-true false "schedule")])
      (secret.close-fixed source)
      (secret.close-fixed destination)
      (secret.close-fixed expected))))

;: Exact constructor boundaries N pass above; N-1 fails before allocation and
;: closes the entire live key capacity for both typed variants.
(test
  aes-key-exact-boundaries
  (let
    [key-128 : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [key-256 : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
    [storage-128 : (MutPtr secret.SecretStorage) key-128.handle.storage]
    [storage-256 : (MutPtr secret.SecretStorage) key-256.handle.storage]
    [before : i64 (profile.alloc-total)]
    (unsafe
      (secret.storage-set-length! storage-128 15))
    (unsafe
      (secret.storage-set-length! storage-256 31))
    (match (aes.new-128 key-128)
      [(Aes128Err (AesSecret (SecretLengthMismatch 16 15))) unit]
      [(Aes128Ok schedule)
        (aes.close-128 schedule)
        (test.assert-true false "short AES-128 key accepted")]
      [_ (test.assert-true false "short AES-128 key error")])
    (match (aes.new-256 key-256)
      [(Aes256Err (AesSecret (SecretLengthMismatch 32 31))) unit]
      [(Aes256Ok schedule)
        (aes.close-256 schedule)
        (test.assert-true false "short AES-256 key accepted")]
      [_ (test.assert-true false "short AES-256 key error")])
    (test.assert-i64-eq
      before
      (profile.alloc-total)
      "short keys allocate nothing")
    (test.assert-true (wiped? storage-128 16) "AES-128 full key capacity wiped")
    (test.assert-true (wiped? storage-256 32) "AES-256 full key capacity wiped")))

;: Replace only public fixture metadata, retaining the same allocated backing.
(define (public-header!
  [storage : (MutPtr secret.SecretStorage)]
  [header : secret.SecretStorage]) : unit
  (unsafe
    (ptr-write! storage header)))

;: Fixed seed 0x7360, 64 malformed metadata mutations per typed variant. Each
;: mutation invalidates exactly one length/capacity/generation/liveness field.
(defmacro (negative-corpus [schedule : Expr] [encrypt : Expr] [length : Expr]) : unit
  `(let
    [source : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [destination : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [expected : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [expanded (& ,(comptime.expr-struct-get schedule "expanded"))]
    [seed : u32 (cast 0x7360 : u32)]
    [index : i64 0]
    (while (< index 64)
      (set! seed (+ (* seed (cast 1664525 : u32)) (cast 1013904223 : u32)))
      (let
        [owner : (MutPtr secret.SecretStorage)
          (if (= (% index 3) 0)
            expanded.handle.storage
            (if (= (% index 3) 1)
              source.handle.storage
              destination.handle.storage))]
        [header : secret.SecretStorage
          (unsafe
            (secret.storage-header owner))]
        [bad : u64
          (+ (cast (bit-and seed (cast 65535 : u32)) : u64) (cast 65537 : u64))]
        (public-header!
          owner
          (match (% index 4)
            [0
              (secret.SecretStorage
                header.state
                header.generation
                bad
                header.capacity)]
            [1
              (secret.SecretStorage
                header.state
                header.generation
                header.length
                bad)]
            [2
              (secret.SecretStorage
                header.state
                bad
                header.length
                header.capacity)]
            [_
              (secret.SecretStorage
                (cast 2 : u64)
                header.generation
                header.length
                header.capacity)]))
        (let
          [before : i64 (profile.alloc-total)]
          (match (,encrypt (& ,schedule) (& source) (&mut destination))
            [(aes.AesErr _) unit]
            [_ (test.assert-true false "malformed owner accepted")])
          (test.assert-i64-eq
            before
            (profile.alloc-total)
            "rejected block allocates nothing"))
        (public-header! owner header)
        (test.assert-true
          (vectors.equal-fixed? (& destination) (& expected))
          "no partial destination on metadata failure"))
      (set! index (+ index 1)))
    (test.assert-i64-eq
      (secret.bytes-length expanded)
      ,length
      "schedule survives rejected calls")
    (secret.close-fixed source)
    (secret.close-fixed destination)
    (secret.close-fixed expected)))

(test
  aes-bounded-metadata-mutation-corpus
  (begin
    (match (aes.new-128 (secret.fixed-zero (secret.Secret16)))
      [(Aes128Ok schedule)
        (negative-corpus schedule aes.encrypt-128! 176)
        (aes.close-128 schedule)]
      [_ (test.assert-true false "AES-128 schedule")])
    (match (aes.new-256 (secret.fixed-zero (secret.Secret32)))
      [(Aes256Ok schedule)
        (negative-corpus schedule aes.encrypt-256! 240)
        (aes.close-256 schedule)]
      [_ (test.assert-true false "AES-256 schedule")])))