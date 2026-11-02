(import stdlib.byte_buf as buf)
(import stdlib.crypto_secret as secret)
(import stdlib.test)

;: An expected-success variable construction.
(define (new-bytes [capacity : i64]) : secret.SecretBytes
  (match (secret.bytes-new capacity)
    [(SecretBytesOk value) value]
    [(SecretBytesErr _)
      (test.assert-true false "variable construction")
      (new-bytes 0)]))

;: An exact public vector, used only for expected test material.
(define (fixed-text [size : secret.SecretSize] [text : String]) : secret.SecretFixed
  (match (secret.fixed-from-bytes size (buf.str-as-bytes (& text)))
    [(SecretFixedOk value) value]
    [(SecretFixedErr _)
      (test.assert-true false "fixed vector construction")
      (secret.fixed-zero size)]))

;: Assert an operation completed.
(define (ok [status : secret.SecretStatus]) : unit
  (match status
    [(SecretOk) unit]
    [(SecretErr _) (test.assert-true false "operation should succeed")]))

;: Public failure classification, including the alias rejection.
(define (error-kind [status : secret.SecretStatus]) : i64
  (match status
    [(SecretOk) 0]
    [(SecretErr (SecretClosed)) 1]
    [(SecretErr (SecretRange _ _ _)) 2]
    [(SecretErr (SecretLengthMismatch _ _)) 3]
    [(SecretErr (SecretAlias)) 4]
    [_ 5]))

;: Full initialized-prefix equality uses the production fixed-work primitive.
(define (equal-bytes
  [left : (& left secret.SecretBytes)]
  [right : (& right secret.SecretBytes)]) : unit
  (match (secret.bytes-equal left right)
    [(SecretCompareOk same) (test.assert-true same "unchanged contents")]
    [_ (test.assert-true false "live equal-length owners")]))

;: Refused ranges must preserve both all bytes and the initialized length.
(define (bad-range
  [source : (& source secret.SecretFixed)]
  [destination : (&mut destination secret.SecretBytes)]
  [expected : (& expected secret.SecretBytes)]
  [source-offset : i64]
  [destination-offset : i64]
  [count : i64]) : unit
  (test.assert-i64-eq
    (error-kind
      (secret.fixed-copy-range!
        source
        (secret.Secret32)
        source-offset
        destination
        destination-offset
        count))
    2
    "range rejected before mutation")
  (test.assert-i64-eq
    (secret.bytes-length destination)
    32
    "failure preserves length")
  (equal-bytes destination expected)
  (test.assert-true
    (=
      (unsafe
        (secret.difference-bits
          (ptr-cast (secret.storage-data destination.handle.storage) : (Ptr u8))
          (ptr-cast (secret.storage-data expected.handle.storage) : (Ptr u8))
          64))
      (cast 0 : u64))
    "failure preserves full capacity"))

;: Boundary writes, untouched gaps, exact lengths and failure atomicity.
(define (range-boundaries) : unit
  (let
    [source : secret.SecretFixed
      (fixed-text (secret.Secret32) "0123456789abcdefghijklmnopqrstuv")]
    [destination : secret.SecretBytes (new-bytes 64)]
    [expected : secret.SecretBytes (new-bytes 64)]
    (ok
      (secret.fixed-copy-range!
        (& source)
        (secret.Secret32)
        0
        (&mut destination)
        0
        32))
    (ok
      (secret.fixed-copy-range!
        (& source)
        (secret.Secret32)
        0
        (&mut expected)
        0
        32))
    (bad-range (& source) (&mut destination) (& expected) -1 0 1)
    (bad-range (& source) (&mut destination) (& expected) 0 -1 1)
    (bad-range (& source) (&mut destination) (& expected) 0 0 -1)
    (bad-range (& source) (&mut destination) (& expected) 32 0 1)
    (bad-range (& source) (&mut destination) (& expected) 33 0 0)
    (bad-range (& source) (&mut destination) (& expected) 0 64 1)
    (bad-range (& source) (&mut destination) (& expected) 0 65 0)
    (bad-range
      (& source)
      (&mut destination)
      (& expected)
      9223372036854775807
      0
      1)
    (bad-range
      (& source)
      (&mut destination)
      (& expected)
      0
      9223372036854775807
      1)
    (bad-range
      (& source)
      (&mut destination)
      (& expected)
      0
      0
      9223372036854775807)
    (bad-range
      (& source)
      (&mut destination)
      (& expected)
      1
      1
      9223372036854775807)
    (test.assert-i64-eq
      (error-kind
        (secret.fixed-copy-range!
          (& source)
          (secret.Secret16)
          0
          (&mut destination)
          0
          1))
      3
      "fixed source length is exact")
    (equal-bytes (& destination) (& expected))
    (ok
      (secret.fixed-copy-range!
        (& source)
        (secret.Secret32)
        32
        (&mut destination)
        64
        0))
    (test.assert-i64-eq
      (secret.bytes-length (& destination))
      64
      "zero count publishes exact end")
    (ok
      (secret.fixed-copy-range!
        (& source)
        (secret.Secret32)
        0
        (&mut destination)
        0
        1))
    (test.assert-i64-eq
      (secret.bytes-length (& destination))
      64
      "overwrite never shrinks")
    (secret.close-fixed source)
    (secret.close-bytes destination)
    (secret.close-bytes expected)))

;: The HKDF range sink retains each source through the next block's write.
(define (consumer-ranges) : unit
  (let
    [output : secret.SecretBytes (new-bytes 8160)]
    [previous : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
    [block : i64 0]
    (while (< block 255)
      (let
        [source : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
        (match (unsafe
          (secret.fixed-write-pointer (&mut source) 0 32))
          [(SecretWriteOk data)
            (let
              [index : i64 0]
              (while (< index 32)
                (unsafe
                  (ptr-write! (ptr-offset data index) (cast (+ block 1) : u8)))
                (set! index (+ index 1))))]
          [_ (test.assert-true false "rotation block live")])
        (test.assert-i64-eq
          (secret.fixed-length (& previous))
          32
          "previous block retained through next creation")
        (ok
          (secret.fixed-copy-range!
            (& source)
            (secret.Secret32)
            0
            (&mut output)
            (* block 32)
            32))
        (test.assert-i64-eq
          (secret.fixed-length (& source))
          32
          "block remains live until retirement")
        (secret.close-fixed previous)
        (set! previous source))
      (set! block (+ block 1)))
    (secret.close-fixed previous)
    (test.assert-i64-eq (secret.bytes-length (& output)) 8160 "255 full blocks")
    (match (unsafe
      (secret.bytes-read-pointer (& output) 0 8160))
      [(SecretReadOk data)
        (let
          [index : i64 0]
          (while (< index 8160)
            (test.assert-i64-eq
              (cast
                (unsafe
                  (ptr-read (ptr-offset data index)))
                : i64)
              (+ (/ index 32) 1)
              "each of 255 distinct blocks")
            (set! index (+ index 1))))]
      [_ (test.assert-true false "full output initialized")])
    (let
      [prefix : secret.SecretBytes (new-bytes 8160)]
      (ok (secret.bytes-copy-range! (& output) 0 (&mut prefix) 0 8128))
      (ok (secret.bytes-copy-range! (& output) 8128 (&mut prefix) 8128 31))
      (test.assert-i64-eq
        (secret.bytes-length (& prefix))
        8159
        "final partial block")
      (ok (secret.bytes-copy-range! (& output) 8159 (&mut prefix) 8159 1))
      (ok (secret.bytes-copy-range! (& output) 8160 (&mut prefix) 8160 0))
      (test.assert-i64-eq
        (secret.bytes-length (& prefix))
        8160
        "zero at capacity")
      (equal-bytes (& output) (& prefix))
      (test.assert-i64-eq
        (error-kind
          (secret.bytes-copy-range! (& prefix) 8160 (&mut output) 8160 1))
        2
        "past final block")
      (secret.close-bytes prefix))
    (secret.close-bytes output))
  (let
    [source : secret.SecretFixed
      (fixed-text
        (secret.Secret48)
        "0123456789abcdefghijklmnopqrstuvABCDEFGHIJKLMNOP")]
    [key : secret.SecretBytes (new-bytes 32)]
    [counter : secret.SecretBytes (new-bytes 16)]
    [joined : secret.SecretBytes (new-bytes 48)]
    [expected : secret.SecretBytes (new-bytes 48)]
    (ok
      (secret.fixed-copy-range! (& source) (secret.Secret48) 0 (&mut key) 0 32))
    (ok
      (secret.fixed-copy-range!
        (& source)
        (secret.Secret48)
        32
        (&mut counter)
        0
        16))
    (ok (secret.bytes-copy-range! (& key) 0 (&mut joined) 0 32))
    (ok (secret.bytes-copy-range! (& counter) 0 (&mut joined) 32 16))
    (ok
      (secret.fixed-copy-range!
        (& source)
        (secret.Secret48)
        0
        (&mut expected)
        0
        48))
    (equal-bytes (& joined) (& expected))
    (secret.close-fixed source)
    (secret.close-bytes key)
    (secret.close-bytes counter)
    (secret.close-bytes joined)
    (secret.close-bytes expected)))

;: Public wrappers can duplicate a storage identity; they cannot bypass checks.
(define (alias-and-liveness) : unit
  (let
    [source : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
    [destination : secret.SecretBytes (new-bytes 64)]
    [alias : secret.SecretBytes (secret.SecretBytes source.handle)]
    [stale : secret.SecretFixed
      (secret.SecretFixed
        (secret.SecretHandle
          source.handle.storage
          (+ source.handle.generation 1)))]
    [stale-destination : secret.SecretBytes
      (secret.SecretBytes
        (secret.SecretHandle
          destination.handle.storage
          (+ destination.handle.generation 1)))]
    (test.assert-i64-eq
      (error-kind
        (secret.fixed-copy-range!
          (& source)
          (secret.Secret32)
          0
          (&mut alias)
          0
          32))
      4
      "exact alias")
    (test.assert-i64-eq
      (error-kind
        (secret.fixed-copy-range!
          (& source)
          (secret.Secret32)
          0
          (&mut alias)
          1
          31))
      4
      "partial overlap")
    (test.assert-i64-eq
      (error-kind
        (secret.fixed-copy-range!
          (& source)
          (secret.Secret32)
          0
          (&mut alias)
          32
          0))
      4
      "zero same-storage alias")
    (test.assert-i64-eq
      (error-kind
        (secret.fixed-copy-range!
          (& stale)
          (secret.Secret32)
          0
          (&mut destination)
          0
          0))
      1
      "stale source")
    (test.assert-i64-eq
      (error-kind
        (secret.fixed-copy-range!
          (& source)
          (secret.Secret32)
          0
          (&mut stale-destination)
          0
          0))
      1
      "stale destination")
    (test.assert-i64-eq
      (secret.bytes-length (& destination))
      0
      "refusal does not initialize")
    (secret.close-fixed source)
    (test.assert-i64-eq
      (error-kind (secret.bytes-copy-range! (& alias) 0 (&mut destination) 0 0))
      1
      "closed source even for zero count")
    (secret.close-bytes destination)
    (let
      [live : secret.SecretBytes (new-bytes 32)]
      [empty-destination : secret.SecretBytes (new-bytes 32)]
      [closed : secret.SecretBytes
        (secret.SecretBytes stale-destination.handle)]
      (test.assert-i64-eq
        (error-kind (secret.bytes-copy-range! (& live) 0 (&mut closed) 0 0))
        1
        "closed destination")
      (test.assert-i64-eq
        (error-kind
          (secret.bytes-copy-range! (& live) 1 (&mut empty-destination) 0 0))
        2
        "source is bounded by initialized length, not capacity")
      (secret.close-bytes closed)
      (secret.close-bytes empty-destination)
      (secret.close-bytes live))
    (secret.close-bytes alias)
    (secret.close-fixed stale)
    (secret.close-bytes stale-destination)))

;: Distinct header pointers still cannot admit overlapping secret ranges.
(define (distinct-overlap) : unit
  (let
    [raw : (MutPtr u64)
      (unsafe
        (ptr-cast (secret.secret-runtime-alloc 128) : (MutPtr u64)))]
    [index : i64 0]
    (while (< index 16)
      (unsafe
        (ptr-write! (ptr-offset raw index) (cast 0 : u64)))
      (set! index (+ index 1)))
    (let
      [source-storage : (MutPtr secret.SecretStorage)
        (unsafe
          (ptr-cast raw : (MutPtr secret.SecretStorage)))]
      [destination-storage : (MutPtr secret.SecretStorage)
        (unsafe
          (ptr-cast (ptr-offset raw 1) : (MutPtr secret.SecretStorage)))]
      (unsafe
        (ptr-write!
          source-storage
          (secret.SecretStorage
            (cast 0 : u64)
            (cast 0 : u64)
            (cast 32 : u64)
            (cast 64 : u64))))
      (unsafe
        (ptr-write!
          destination-storage
          (secret.SecretStorage
            (cast 0 : u64)
            (cast 32 : u64)
            (cast 64 : u64)
            (cast 64 : u64))))
      (let
        [source : secret.SecretBytes
          (secret.SecretBytes (secret.SecretHandle source-storage 0))]
        [destination : secret.SecretBytes
          (secret.SecretBytes (secret.SecretHandle destination-storage 32))]
        (test.assert-i64-eq
          (error-kind
            (secret.bytes-copy-range! (& source) 0 (&mut destination) 0 16))
          4
          "different header pointers still overlap")
        (test.assert-i64-eq
          (error-kind
            (secret.bytes-copy-range! (& destination) 0 (&mut source) 0 16))
          4
          "reverse partial overlap")
        (test.assert-true
          (=
            (unsafe
              (ptr-read (ptr-offset raw 4)))
            (cast 64 : u64))
          "overlap preserves backing bytes")
        (test.assert-i64-eq
          (secret.bytes-length (& source))
          32
          "overlap preserves source length")
        (test.assert-i64-eq
          (secret.bytes-length (& destination))
          64
          "overlap preserves destination length")
        (secret.close-bytes source)
        (secret.close-bytes destination)))))

;: A transferred source retains its bytes and address but invalidates aliases.
(unsafe
  (define (nominal-inner [handle : secret.SecretNominalHandle]) : secret.SecretHandle
    (let
      [words : (MutPtr u64)
        (unsafe
          (ptr-cast handle.storage : (MutPtr u64)))]
      (secret.SecretHandle
        (unsafe
          (int->ptr
            (ptr-read (ptr-offset words 2))
            : (MutPtr secret.SecretStorage)))
        (cast
          (unsafe
            (ptr-read (ptr-offset words 3)))
          : i64)))))

;: Test-only unsafe inspection of the retained outer header after cleanup.
(define (outer-state [handle : secret.SecretNominalHandle]) : u64
  (unsafe
    (ptr-read (ptr-cast handle.storage : (Ptr u64)))))

;: A transferred source retains its bytes and address but invalidates aliases.
(define (nominal-lifecycle) : unit
  (let
    [source : secret.SecretFixed
      (fixed-text (secret.Secret32) "0123456789abcdefghijklmnopqrstuv")]
    [expected : secret.SecretFixed
      (fixed-text (secret.Secret32) "0123456789abcdefghijklmnopqrstuv")]
    [old : secret.SecretHandle source.handle]
    (match (unsafe
      (secret.transfer-fixed source (secret.Secret32)))
      [(SecretNominalErr _) (test.assert-true false "live exact transfer")]
      [(SecretNominalOk owner)
        (let
          [handle : secret.SecretNominalHandle owner.handle]
          [inner : secret.SecretHandle
            (unsafe
              (nominal-inner handle))]
          (test.assert-true
            (= inner.storage old.storage)
            "no byte allocation or copy")
          (test.assert-false
            (= inner.generation old.generation)
            "transfer rotates generation")
          (secret.nominal-handle-close
            (secret.SecretNominalHandle handle.storage (+ handle.generation 1)))
          (let
            [stale : secret.SecretFixed (secret.SecretFixed old)]
            (test.assert-i64-eq
              (secret.fixed-length (& stale))
              0
              "old handle is stale")
            (secret.close-fixed stale))
          (secret.storage-close old)
          (match (unsafe
            (secret.nominal-read-pointer (& owner) 0 32))
            [(SecretReadOk data)
              (test.assert-true
                (=
                  (unsafe
                    (secret.difference-bits
                      data
                      (ptr-cast
                        (secret.storage-data expected.handle.storage)
                        : (Ptr u8))
                      32))
                  (cast 0 : u64))
                "transfer preserves every byte")
              (test.assert-i64-eq
                (cast
                  (unsafe
                    (ptr-read data))
                  : i64)
                48
                "stale close cannot wipe new generation")]
            [_ (test.assert-true false "nominal state remains live")])
          (secret.close-nominal owner)
          (secret.nominal-handle-close handle)
          (test.assert-true
            (= (outer-state handle) (secret.state-closed))
            "outer closed")
          (test.assert-true
            (=
              (unsafe
                (secret.storage-header inner.storage)).state
              (secret.state-closed))
            "inner closed")
          (test.assert-true
            (=
              (unsafe
                (secret.storage-header inner.storage)).length
              (cast 0 : u64))
            "inner length wiped")
          (let
            [index : i64 0]
            [data : (MutPtr u8)
              (unsafe
                (secret.storage-data inner.storage))]
            (while (< index 32)
              (test.assert-i64-eq
                (cast
                  (unsafe
                    (ptr-read (ptr-offset data index)))
                  : i64)
                0
                "inner capacity wiped")
              (set! index (+ index 1)))
            (unsafe
              (ptr-write!
                inner.storage
                (secret.SecretStorage
                  (secret.state-live)
                  (cast inner.generation : u64)
                  (cast 32 : u64)
                  (cast 32 : u64))))
            (unsafe
              (ptr-write! data (cast 77 : u8)))
            (secret.nominal-handle-close handle)
            (test.assert-i64-eq
              (cast
                (unsafe
                  (ptr-read data))
                : i64)
              77
              "outer invokes inner cleanup exactly once")
            (secret.storage-close inner)))])
    (secret.close-fixed expected))
  (let
    [wrong : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [handle : secret.SecretHandle wrong.handle]
    (match (unsafe
      (secret.transfer-fixed wrong (secret.Secret32)))
      [(SecretNominalErr (SecretLengthMismatch _ _)) unit]
      [(SecretNominalErr _) (test.assert-true false "exact nominal length")]
      [(SecretNominalOk owner)
        (test.assert-true false "wrong length transferred")
        (secret.close-nominal owner)])
    (test.assert-true
      (=
        (unsafe
          (secret.storage-header handle.storage)).state
        (secret.state-closed))
      "failed transfer cleans consumed source")))

;: Both stdlib verifiers and the opt0/1/2 codegen runtime rows use this corpus.
(define (transfer-failures) : unit
  (let
    [source : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
    [handle : secret.SecretHandle source.handle]
    [stale : secret.SecretFixed
      (secret.SecretFixed
        (secret.SecretHandle handle.storage (+ handle.generation 1)))]
    (match (unsafe
      (secret.transfer-fixed stale (secret.Secret32)))
      [(SecretNominalErr (SecretClosed)) unit]
      [(SecretNominalErr _)
        (test.assert-true false "stale transfer classification")]
      [(SecretNominalOk owner)
        (test.assert-true false "stale transfer accepted")
        (secret.close-nominal owner)])
    (test.assert-i64-eq
      (secret.fixed-length (& source))
      32
      "stale transfer preserves live generation")
    (secret.close-fixed source)
    (let
      [closed : secret.SecretFixed (secret.SecretFixed handle)]
      (match (unsafe
        (secret.transfer-fixed closed (secret.Secret32)))
        [(SecretNominalErr (SecretClosed)) unit]
        [(SecretNominalErr _)
          (test.assert-true false "closed transfer classification")]
        [(SecretNominalOk owner)
          (test.assert-true false "closed transfer accepted")
          (secret.close-nominal owner)])))
  (let
    [variable : secret.SecretBytes (new-bytes 64)]
    [destination : secret.SecretBytes (new-bytes 32)]
    [fixed : secret.SecretFixed (secret.SecretFixed variable.handle)]
    (ok
      (unsafe
        (secret.bytes-set-length! (&mut variable) 32)))
    (test.assert-i64-eq
      (error-kind
        (secret.fixed-copy-range!
          (& fixed)
          (secret.Secret32)
          0
          (&mut destination)
          0
          0))
      3
      "fixed copy checks capacity even for zero count")
    (test.assert-i64-eq
      (secret.bytes-length (& destination))
      0
      "bad fixed source preserves destination")
    (match (unsafe
      (secret.transfer-fixed fixed (secret.Secret32)))
      [(SecretNominalErr (SecretLengthMismatch _ _)) unit]
      [(SecretNominalErr _)
        (test.assert-true false "fixed capacity classification")]
      [(SecretNominalOk owner)
        (test.assert-true false "variable-capacity fixed transfer accepted")
        (secret.close-nominal owner)])
    (secret.close-bytes variable)
    (secret.close-bytes destination)))

;: Lexical cleanup retires nested state on both ordinary and early exits.
(define (scoped-transfer [early : bool]) : secret.SecretNominalHandle
  (match (unsafe
    (secret.transfer-fixed
      (secret.fixed-zero (secret.Secret32))
      (secret.Secret32)))
    [(SecretNominalErr _)
      (test.assert-true false "scoped transfer")
      (secret.SecretNominalHandle
        (ptr-null : (MutPtr secret.SecretNominalStorage))
        0)]
    [(SecretNominalOk owner)
      (let
        [seen : secret.SecretNominalHandle owner.handle]
        (with
          ([nominal owner secret.close-nominal])
          (when early (return seen))
          unit)
        seen)]))

;: Both stdlib verifiers and the opt0/1/2 codegen runtime rows use this corpus.
(define (main) : i64
  (range-boundaries)
  (consumer-ranges)
  (alias-and-liveness)
  (distinct-overlap)
  (nominal-lifecycle)
  (transfer-failures)
  (let
    [normal : secret.SecretNominalHandle (scoped-transfer false)]
    [early : secret.SecretNominalHandle (scoped-transfer true)]
    (test.assert-true
      (= (outer-state normal) (secret.state-closed))
      "lexical nominal close")
    (test.assert-true
      (= (outer-state early) (secret.state-closed))
      "early nominal close"))
  42)