(cfg test (import stdlib.byte_buf))
(cfg test (import stdlib.crypto_secret as secret))
(cfg test (import stdlib.test))

;: Header snapshot of storage the test still points at after its owner closed.
(cfg
  test
  (define (test-header [storage : (MutPtr secret.SecretStorage)]) : secret.SecretStorage
    (unsafe
      (secret.storage-header storage))))

;: Whether every one of the first `count` data bytes of `storage` is zero.
(cfg
  test
  (define (test-data-zero?
    [storage : (MutPtr secret.SecretStorage)]
    [count : i64]) : bool
    (let
      [data : (MutPtr u8)
        (unsafe
          (secret.storage-data storage))]
      [zero : bool true]
      [index : i64 0]
      (while (< index count)
        (when
          (not
            (=
              (unsafe
                (ptr-read (ptr-offset data index)))
              (cast 0 : u8)))
          (set! zero false))
        (set! index (+ index 1)))
      zero)))

;: Unwrap a fixed construction the test expects to succeed.
(cfg
  test
  (define (test-fixed [result : secret.SecretFixedResult]) : secret.SecretFixed
    (match result
      [(SecretFixedOk value) value]
      [(SecretFixedErr _)
        (test.assert-true false "fixed construction should succeed")
        (secret.fixed-zero (secret.Secret16))])))

;: Unwrap a variable construction the test expects to succeed.
(cfg
  test
  (define (test-bytes [result : secret.SecretBytesResult]) : secret.SecretBytes
    (match result
      [(SecretBytesOk value) value]
      [(SecretBytesErr _)
        (test.assert-true false "variable construction should succeed")
        (test-bytes (secret.bytes-new 0))])))

;: A fixed owner of `size` holding the bytes of `text`.
(cfg
  test
  (define (test-fixed-text [size : secret.SecretSize] [text : String]) : secret.SecretFixed
    (test-fixed (secret.fixed-from-bytes size (byte_buf.str-as-bytes (& text))))))

;: The boolean of a comparison the test expects to complete.
(cfg
  test
  (define (test-equal-ok [result : secret.SecretCompareResult]) : bool
    (match result
      [(SecretCompareOk equal) equal]
      [(SecretCompareErr _)
        (test.assert-true false "comparison should complete")
        false])))

;: Whether a comparison failed because an owner was closed or stale.
(cfg
  test
  (define (test-compare-closed? [result : secret.SecretCompareResult]) : bool
    (match result
      [(SecretCompareErr (SecretClosed)) true]
      [_ false])))

(cfg
  test
  (test
    crypto-secret-fixed-sizes
    (let
      [sizes : (Array secret.SecretSize 5)
        (array
          (secret.Secret16)
          (secret.Secret20)
          (secret.Secret32)
          (secret.Secret48)
          (secret.Secret64))]
      [expected : (Array i64 5) (array 16 20 32 48 64)]
      [index : i64 0]
      (while (< index 5)
        (let
          [owner : secret.SecretFixed
            (secret.fixed-zero (array-ref sizes index))]
          (test.assert-i64-eq
            (secret.fixed-length (& owner))
            (array-ref expected index)
            "fixed owner length")
          (secret.close-fixed owner))
        (set! index (+ index 1))))))

(cfg
  test
  (test
    crypto-secret-fixed-construction-and-equality
    (let
      [short : String "abc"]
      [base : secret.SecretFixed
        (test-fixed-text (secret.Secret20) "0123456789abcdefghij")]
      [same : secret.SecretFixed
        (test-fixed-text (secret.Secret20) "0123456789abcdefghij")]
      [first : secret.SecretFixed
        (test-fixed-text (secret.Secret20) "x123456789abcdefghij")]
      [last : secret.SecretFixed
        (test-fixed-text (secret.Secret20) "0123456789abcdefghix")]
      [other-size : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
      (match (secret.fixed-from-bytes
        (secret.Secret32)
        (byte_buf.str-as-bytes (& short)))
        [(SecretFixedErr (SecretLengthMismatch expected actual))
          (test.assert-i64-eq expected 32 "expected length")
          (test.assert-i64-eq actual 3 "actual length")]
        [(SecretFixedErr _)
          (test.assert-true false "wrong error for a short source")]
        [(SecretFixedOk owner)
          (test.assert-true false "short source must be rejected")
          (secret.close-fixed owner)])
      (test.assert-true
        (test-equal-ok (secret.fixed-equal (& base) (& same)))
        "equal secrets")
      (test.assert-false
        (test-equal-ok (secret.fixed-equal (& base) (& first)))
        "first byte differs")
      (test.assert-false
        (test-equal-ok (secret.fixed-equal (& base) (& last)))
        "last byte differs")
      (match (secret.fixed-equal (& base) (& other-size))
        [(SecretCompareErr (SecretLengthMismatch left right))
          (test.assert-i64-eq left 20 "left length")
          (test.assert-i64-eq right 32 "right length")]
        [_ (test.assert-true false "sizes must match before comparing")])
      (secret.close-fixed base)
      (secret.close-fixed same)
      (secret.close-fixed first)
      (secret.close-fixed last)
      (secret.close-fixed other-size))))

(cfg
  test
  (test
    crypto-secret-variable-bounds
    (let
      [text : String "abcde"]
      [empty : secret.SecretBytes (test-bytes (secret.bytes-new 0))]
      [largest : secret.SecretBytes
        (test-bytes (secret.bytes-new (secret.max-capacity)))]
      [okm : secret.SecretBytes
        (test-bytes
          (secret.bytes-from-bytes (byte_buf.str-as-bytes (& text)) 8160))]
      (match (secret.bytes-new -1)
        [(SecretBytesErr (SecretBadLength capacity))
          (test.assert-i64-eq capacity -1 "negative capacity")]
        [(SecretBytesErr _) (test.assert-true false "wrong error")]
        [(SecretBytesOk owner)
          (test.assert-true false "negative capacity accepted")
          (secret.close-bytes owner)])
      (match (secret.bytes-new (+ (secret.max-capacity) 1))
        [(SecretBytesErr (SecretBadLength _)) unit]
        [(SecretBytesErr _) (test.assert-true false "wrong error")]
        [(SecretBytesOk owner)
          (test.assert-true false "oversized capacity accepted")
          (secret.close-bytes owner)])
      (match (secret.bytes-from-bytes (byte_buf.str-as-bytes (& text)) 4)
        [(SecretBytesErr (SecretLengthMismatch capacity length))
          (test.assert-i64-eq capacity 4 "capacity")
          (test.assert-i64-eq length 5 "length")]
        [(SecretBytesErr _) (test.assert-true false "wrong error")]
        [(SecretBytesOk owner)
          (test.assert-true false "source past capacity accepted")
          (secret.close-bytes owner)])
      (test.assert-i64-eq (secret.bytes-length (& empty)) 0 "live empty length")
      (test.assert-i64-eq
        (secret.bytes-capacity (& empty))
        0
        "live empty capacity")
      (test.assert-true
        (test-equal-ok (secret.bytes-equal (& empty) (& empty)))
        "two empty prefixes are equal")
      (test.assert-i64-eq
        (secret.bytes-capacity (& largest))
        (secret.max-capacity)
        "largest capacity")
      (test.assert-i64-eq (secret.bytes-length (& okm)) 5 "initialized prefix")
      (test.assert-i64-eq (secret.bytes-capacity (& okm)) 8160 "HKDF capacity")
      (secret.close-bytes empty)
      (secret.close-bytes largest)
      (secret.close-bytes okm))))

(cfg
  test
  (test
    crypto-secret-close-poisons-and-wipes
    (let
      [owner : secret.SecretFixed
        (test-fixed-text (secret.Secret20) "0123456789abcdefghij")]
      [storage : (MutPtr secret.SecretStorage) owner.storage]
      [generation : i64 owner.generation]
      (test.assert-false (test-data-zero? storage 20) "secret is present")
      (secret.close-fixed owner)
      (test.assert-true
        (= (test-header storage).state (cast 2 : u64))
        "storage is closed")
      (test.assert-true
        (= (test-header storage).length (cast 0 : u64))
        "length is wiped")
      (test.assert-true
        (test-data-zero? storage 24)
        "every capacity byte is wiped")
      (secret.storage-close storage)
      (test.assert-true
        (= (test-header storage).state (cast 2 : u64))
        "closing again changes nothing")
      (let
        [stale : secret.SecretFixed (secret.SecretFixed storage generation)]
        (test.assert-i64-eq (secret.fixed-length (& stale)) 0 "closed length")
        (test.assert-true
          (test-compare-closed? (secret.fixed-equal (& stale) (& stale)))
          "closed owners do not compare")
        (secret.close-fixed stale)))))

;: Return the storage of an owner cleaned by `with` on the normal or the
;: early-return path.
(cfg
  test
  (define (test-scoped-storage [early : bool]) : (MutPtr secret.SecretStorage)
    (let
      [seen : (MutPtr secret.SecretStorage)
        (ptr-null : (MutPtr secret.SecretStorage))]
      (with
        ([owner (secret.fixed-zero (secret.Secret32)) secret.close-fixed])
        (set! seen owner.storage)
        (when early (return seen))
        unit)
      seen)))

(cfg
  test
  (test
    crypto-secret-lexical-cleanup
    (begin
      (test.assert-true
        (= (test-header (test-scoped-storage false)).state (cast 2 : u64))
        "scope exit closes")
      (test.assert-true
        (= (test-header (test-scoped-storage true)).state (cast 2 : u64))
        "early return closes"))))

(cfg
  test
  (test
    crypto-secret-stale-generation
    (let
      [owner : secret.SecretFixed
        (test-fixed-text (secret.Secret16) "0123456789abcdef")]
      [forged : secret.SecretFixed
        (secret.SecretFixed owner.storage (+ owner.generation 1))]
      (test.assert-i64-eq (secret.fixed-length (& forged)) 0 "stale stamp")
      (test.assert-true
        (test-compare-closed? (secret.fixed-equal (& owner) (& forged)))
        "stale owner does not compare")
      (match (unsafe
        (secret.fixed-read-pointer (& forged) 0 1))
        [(SecretReadErr (SecretClosed)) unit]
        [_ (test.assert-true false "stale owner yields no pointer")])
      (test.assert-i64-eq (secret.fixed-length (& owner)) 16 "owner still live")
      (secret.close-fixed owner)
      (secret.close-fixed forged))))

(cfg
  test
  (test
    crypto-secret-pointer-ranges
    (let
      [text : String "0123456789abcdef"]
      [owner : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
      [expected : secret.SecretFixed
        (test-fixed-text (secret.Secret16) "0123456789abcdef")]
      [checks : (Array i64 8) (array -1 1 0 -1 0 17 16 1)]
      [index : i64 0]
      (while (< index 8)
        (match (unsafe
          (secret.fixed-write-pointer
            (&mut owner)
            (array-ref checks index)
            (array-ref checks (+ index 1))))
          [(SecretWriteErr (SecretRange _ _ limit))
            (test.assert-i64-eq limit 16 "range limit")]
          [_ (test.assert-true false "out-of-range write must be rejected")])
        (set! index (+ index 2)))
      (test.assert-true
        (test-equal-ok
          (secret.fixed-equal
            (& owner)
            (& (secret.fixed-zero (secret.Secret16)))))
        "rejected requests change nothing")
      (match (unsafe
        (secret.fixed-write-pointer (&mut owner) 0 16))
        [(SecretWriteOk data)
          (let
            [byte-index : i64 0]
            (while (< byte-index 16)
              (unsafe
                (ptr-write!
                  (ptr-offset data byte-index)
                  (byte_buf.bytes-ref
                    (byte_buf.str-as-bytes (& text))
                    byte-index)))
              (set! byte-index (+ byte-index 1))))]
        [(SecretWriteErr _) (test.assert-true false "full write range")])
      (test.assert-true
        (test-equal-ok (secret.fixed-equal (& owner) (& expected)))
        "written bytes are read back")
      (match (unsafe
        (secret.fixed-read-pointer (& owner) 15 1))
        [(SecretReadOk data)
          (test.assert-i64-eq
            (cast
              (unsafe
                (ptr-read data))
              : i64)
            102
            "last byte")]
        [(SecretReadErr _) (test.assert-true false "last-byte read")])
      (match (unsafe
        (secret.fixed-read-pointer (& owner) 16 0))
        [(SecretReadOk _) unit]
        [(SecretReadErr _) (test.assert-true false "empty range at the end")])
      (secret.close-fixed owner)
      (secret.close-fixed expected))))

(cfg
  test
  (test
    crypto-secret-set-length
    (let
      [owner : secret.SecretBytes (test-bytes (secret.bytes-new 16))]
      (match (unsafe
        (secret.bytes-write-pointer (&mut owner) 0 10))
        [(SecretWriteOk data)
          (let
            [index : i64 0]
            (while (< index 10)
              (unsafe
                (ptr-write! (ptr-offset data index) (cast 7 : u8)))
              (set! index (+ index 1))))]
        [(SecretWriteErr _) (test.assert-true false "write within capacity")])
      (match (unsafe
        (secret.bytes-read-pointer (& owner) 0 1))
        [(SecretReadErr (SecretRange _ _ limit))
          (test.assert-i64-eq limit 0 "unpublished bytes are not readable")]
        [_ (test.assert-true false "read past the initialized length")])
      (match (unsafe
        (secret.bytes-set-length! (&mut owner) 17))
        [(SecretErr (SecretRange _ _ limit))
          (test.assert-i64-eq limit 16 "capacity")]
        [_ (test.assert-true false "length past capacity")])
      (match (unsafe
        (secret.bytes-set-length! (&mut owner) 10))
        [(SecretOk) unit]
        [(SecretErr _) (test.assert-true false "publish written bytes")])
      (test.assert-i64-eq (secret.bytes-length (& owner)) 10 "published length")
      (match (unsafe
        (secret.bytes-set-length! (&mut owner) 4))
        [(SecretOk) unit]
        [(SecretErr _) (test.assert-true false "shrink")])
      (let
        [data : (MutPtr u8)
          (unsafe
            (secret.storage-data owner.storage))]
        (test.assert-i64-eq
          (cast
            (unsafe
              (ptr-read (ptr-offset data 3)))
            : i64)
          7
          "kept byte")
        (test.assert-i64-eq
          (cast
            (unsafe
              (ptr-read (ptr-offset data 4)))
            : i64)
          0
          "released bytes are zeroed"))
      (secret.close-bytes owner))))

(cfg
  test
  (test
    crypto-secret-masks-and-selects
    (let
      [ones : u64 (bit-not (cast 0 : u64))]
      [zero : u64 (cast 0 : u64)]
      [a : u64 (cast 0x1122334455667788 : u64)]
      [b : u64 (cast 0x99aabbccddeeff00 : u64)]
      [x : u32 (cast 0x11223344 : u32)]
      [y : u32 (cast 0x55667788 : u32)]
      [p : u8 (cast 0x5a : u8)]
      [q : u8 (cast 0xa5 : u8)]
      (test.assert-true (= (secret.mask-u64 (cast 1 : u64)) ones) "bit one")
      (test.assert-true
        (= (secret.mask-u64 (cast 2 : u64)) zero)
        "only the low bit")
      (test.assert-true (= (secret.mask-u64 (cast 3 : u64)) ones) "low bit set")
      (test.assert-true (= (secret.nonzero-mask-u64 zero) zero) "zero")
      (test.assert-true (= (secret.nonzero-mask-u64 (cast 1 : u64)) ones) "one")
      (test.assert-true (= (secret.nonzero-mask-u64 ones) ones) "all ones")
      (test.assert-true
        (= (secret.nonzero-mask-u64 (shl (cast 1 : u64) (cast 63 : u64))) ones)
        "top bit")
      (test.assert-true (= (secret.select-u64 ones a b) a) "select u64 a")
      (test.assert-true (= (secret.select-u64 zero a b) b) "select u64 b")
      (test.assert-true
        (= (secret.select-u32 (cast 0xffffffff : u32) x y) x)
        "select u32 a")
      (test.assert-true
        (= (secret.select-u32 (cast 0 : u32) x y) y)
        "select u32 b")
      (test.assert-true
        (= (secret.select-u8 (cast 255 : u8) p q) p)
        "select u8 a")
      (test.assert-true
        (= (secret.select-u8 (cast 0 : u8) p q) q)
        "select u8 b")
      (secret.swap-u64! zero (&mut a) (&mut b))
      (test.assert-true (= a (cast 0x1122334455667788 : u64)) "no swap keeps a")
      (secret.swap-u64! ones (&mut a) (&mut b))
      (test.assert-true (= a (cast 0x99aabbccddeeff00 : u64)) "swap u64 a")
      (test.assert-true (= b (cast 0x1122334455667788 : u64)) "swap u64 b")
      (secret.swap-u32! (cast 0xffffffff : u32) (&mut x) (&mut y))
      (test.assert-true (= x (cast 0x55667788 : u32)) "swap u32")
      (secret.swap-u8! (cast 255 : u8) (&mut p) (&mut q))
      (test.assert-true (= p (cast 0xa5 : u8)) "swap u8"))))

(cfg
  test
  (test
    crypto-secret-wipe-words
    (let
      [scratch : (Array u64 4)
        (array (cast 1 : u64) (cast 2 : u64) (cast 3 : u64) (cast 4 : u64))]
      (unsafe
        (secret.wipe-words! (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)) 4))
      (test.assert-true
        (and
          (= (array-ref scratch 0) (cast 0 : u64))
          (= (array-ref scratch 3) (cast 0 : u64)))
        "caller scratch is wiped"))))

(cfg
  test
  (test
    crypto-secret-structural-equality-is-identity
    (let
      [left : secret.SecretFixed
        (test-fixed-text (secret.Secret16) "0123456789abcdef")]
      [right : secret.SecretFixed
        (test-fixed-text (secret.Secret16) "0123456789abcdef")]
      (test.assert-false (= left right) "equal bytes in distinct owners")
      (test.assert-true
        (test-equal-ok (secret.fixed-equal (& left) (& right)))
        "content comparison")
      (secret.close-fixed left)
      (secret.close-fixed right))))