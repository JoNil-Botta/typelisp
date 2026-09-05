(cfg test (import stdlib.byte_buf))
(cfg test (import stdlib.crypto_sha512 as sha))
(cfg test (import stdlib.test))

;: Return a zero SHA-512 digest after recording an unexpected test failure.
(cfg
  test
  (define (test-zero-digest [message : String]) : sha.Sha512Digest
    (begin
      (test.assert-true false message)
      (sha.Sha512Digest (init)))))

;: Require one successful SHA-512 state update in inline tests.
(cfg
  test
  (define (test-require-update [result : sha.Sha512UpdateResult]) : unit
    (match result
      [(sha.Sha512UpdateOk) unit]
      [(sha.Sha512UpdateErr _)
        (test.assert-true false "SHA-512 update should succeed")])))

;: Extract one successful final digest in inline tests.
(cfg
  test
  (define (test-require-finalize [result : sha.Sha512FinalizeResult]) : sha.Sha512Digest
    (match result
      [(sha.Sha512FinalizeOk value) value]
      [(sha.Sha512FinalizeErr _)
        (test-zero-digest "SHA-512 finalization should succeed")])))

;: Hash one borrowed test byte range.
(cfg
  test
  (define (test-digest [input : (& input bytes)]) : sha.Sha512Digest
    (test-require-finalize (sha.digest input))))

;: Assert one one-shot text vector.
(cfg
  test
  (define (test-assert-vector [text : String] [expected : String]) : unit
    (let
      [result : sha.Sha512Digest (test-digest (byte_buf.str-as-bytes (& text)))]
      [actual : String (sha.to-hex (& result))]
      (begin
        (test.assert-i64-eq
          (array-length (sha.digest-bytes (& result)))
          64
          "SHA-512 digest width")
        (test.assert-i64-eq
          (string-length (& actual))
          128
          "SHA-512 hexadecimal width")
        (test.assert-string-eq (& actual) (& expected) "SHA-512 vector")))))

;: Construct `count` copies of one byte for padding-boundary tests.
(cfg
  test
  (define (test-repeated-bytes [count : i64] [value : u8]) : byte_buf.ByteBuf
    (let
      [buf : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 count))]
      [index : i64 0]
      (begin
        (while (< index count)
          (begin
            (set! buf (byte_buf.set! buf index value))
            (set! index (+ index 1))))
        buf))))

;: Assert one repeated-byte padding-boundary vector.
(cfg
  test
  (define (test-assert-repeated-vector [count : i64] [expected : String]) : unit
    (let
      [buf : byte_buf.ByteBuf (test-repeated-bytes count (cast 'a' : u8))]
      [result : sha.Sha512Digest (test-digest (byte_buf.as-bytes (& buf)))]
      [actual : String (sha.to-hex (& result))]
      (test.assert-string-eq (& actual) (& expected) "SHA-512 padding vector"))))

;: Check every two-chunk split and byte-at-a-time streaming against one-shot.
(cfg
  test
  (define (test-streaming-splits [text : String]) : unit
    (let
      [input : (& text bytes) (byte_buf.str-as-bytes (& text))]
      [expected : sha.Sha512Digest (test-digest input)]
      [input-length : i64 (byte_buf.bytes-length input)]
      [split : i64 0]
      (begin
        (while (<= split input-length)
          (let
            [state : sha.Sha512State (sha.new)]
            [left : (& text bytes) (byte_buf.bytes-slice-view input 0 split)]
            [right : (& text bytes)
              (byte_buf.bytes-slice-view input split (- input-length split))]
            (begin
              (test-require-update (sha.update! (&mut state) left))
              (test-require-update (sha.update! (&mut state) right))
              (let
                [actual : sha.Sha512Digest
                  (test-require-finalize (sha.finalize! (&mut state)))]
                (test.assert-true
                  (sha.digest-eq? (& actual) (& expected))
                  "SHA-512 split digest"))
              (set! split (+ split 1)))))
        (let
          [state : sha.Sha512State (sha.new)]
          [index : i64 0]
          (begin
            (while (< index input-length)
              (begin
                (test-require-update
                  (sha.update!
                    (&mut state)
                    (byte_buf.bytes-slice-view input index 1)))
                (set! index (+ index 1))))
            (let
              [actual : sha.Sha512Digest
                (test-require-finalize (sha.finalize! (&mut state)))]
              (test.assert-true
                (sha.digest-eq? (& actual) (& expected))
                "SHA-512 byte-at-a-time digest"))))))))

;: Require the common finalized-state lifecycle error.
(cfg
  test
  (define (test-assert-finalized-update [result : sha.Sha512UpdateResult]) : unit
    (match result
      [(sha.Sha512UpdateErr (sha.Sha512Finalized)) unit]
      [_ (test.assert-true false "expected finalized SHA-512 update error")])))

;: Require the common finalized-state finalization error.
(cfg
  test
  (define (test-assert-finalized-finalize [result : sha.Sha512FinalizeResult]) : unit
    (match result
      [(sha.Sha512FinalizeErr (sha.Sha512Finalized)) unit]
      [_
        (test.assert-true false "expected finalized SHA-512 finalization error")])))

;: Require one public-length overflow result.
(cfg
  test
  (define (test-assert-length-error [result : sha.Sha512LengthResult]) : unit
    (match result
      [(sha.Sha512LengthErr (sha.Sha512MessageTooLong _ _ _)) unit]
      [_ (test.assert-true false "expected SHA-512 length error")])))

;: Require a raw-source validation error without inspecting pointer contents.
(cfg
  test
  (define (test-assert-source-error [result : sha.Sha512UpdateResult]) : unit
    (match result
      [(sha.Sha512UpdateErr (sha.Sha512InvalidSource)) unit]
      [(sha.Sha512UpdateErr (sha.Sha512InvalidSourceLength _)) unit]
      [_ (test.assert-true false "expected SHA-512 source error")])))

;: Require an exact-output validation error without inspecting sink contents.
(cfg
  test
  (define (test-assert-output-error [result : sha.Sha512FinalizeIntoResult]) : unit
    (match result
      [(sha.Sha512FinalizeIntoErr (sha.Sha512InvalidOutput)) unit]
      [(sha.Sha512FinalizeIntoErr (sha.Sha512InvalidOutputLength _)) unit]
      [_ (test.assert-true false "expected SHA-512 output error")])))

;: Require successful finalization through the raw exact-sink seam.
(cfg
  test
  (define (test-require-finalize-into [result : sha.Sha512FinalizeIntoResult]) : unit
    (match result
      [(sha.Sha512FinalizeIntoOk) unit]
      [(sha.Sha512FinalizeIntoErr _)
        (test.assert-true false "SHA-512 sink finalization should succeed")])))

(cfg
  test
  (test
    crypto-sha512-fips-vectors
    (begin
      (test-assert-vector
        ""
        "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
      (test-assert-vector
        "abc"
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
      (test-assert-vector
        "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909"))))

(cfg
  test
  (test
    crypto-sha512-padding-boundaries
    (begin
      (test-assert-repeated-vector
        111
        "fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef86818196921760b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2")
      (test-assert-repeated-vector
        112
        "c01d080efd492776a1c43bd23dd99d0a2e626d481e16782e75d54c2503b5dc32bd05f0f1ba33e568b88fd2d970929b719ecbb152f58f130a407c8830604b70ca")
      (test-assert-repeated-vector
        127
        "828613968b501dc00a97e08c73b118aa8876c26b8aac93df128502ab360f91bab50a51e088769a5c1eff4782ace147dce3642554199876374291f5d921629502")
      (test-assert-repeated-vector
        128
        "b73d1929aa615934e61a871596b3f3b33359f42b8175602e89f7e06e5f658a243667807ed300314b95cacdd579f3e33abdfbe351909519a846d465c59582f321")
      (test-assert-repeated-vector
        129
        "4f681e0bd53cda4b5a2041cc8a06f2eabde44fb16c951fbd5b87702f07aeab611565b19c47fde30587177ebb852e3971bbd8d3fd30da18d71037dfbd98420429")
      (test-assert-repeated-vector
        256
        "6a9169eb662f136d87374070e8828b3e615a7eca32a89446e9225b02832709be095e635c824a2bb70213ba2ea0ababac0809827843992c851903b7ac0c136699"))))

(cfg
  test
  (test
    crypto-sha512-streaming
    (begin
      (test-streaming-splits "")
      (test-streaming-splits "abc")
      (test-streaming-splits
        "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"))))

(cfg
  test
  (test
    crypto-sha512-million-a
    (let
      [chunk : byte_buf.ByteBuf (test-repeated-bytes 1000 (cast 'a' : u8))]
      [state : sha.Sha512State (sha.new)]
      [count : i64 0]
      (begin
        (while (< count 1000)
          (begin
            (test-require-update
              (sha.update! (&mut state) (byte_buf.as-bytes (& chunk))))
            (set! count (+ count 1))))
        (let
          [result : sha.Sha512Digest
            (test-require-finalize (sha.finalize! (&mut state)))]
          [actual : String (sha.to-hex (& result))]
          [expected : String
            "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b"]
          (test.assert-string-eq
            (& actual)
            (& expected)
            "SHA-512 million-a vector"))))))

(cfg
  test
  (test
    crypto-sha512-scoped-pointer-seam
    (let
      [text : String
        "public equivalence input crossing one SHA-512 block........................................................................"]
      [input : (& text bytes) (byte_buf.str-as-bytes (& text))]
      [expected : sha.Sha512Digest (test-digest input)]
      [state : sha.Sha512State (sha.new)]
      [output : (Array u8 64) (init)]
      [source : (Ptr u8)
        (unsafe
          (byte_buf.bytes-data input))]
      [sink : (MutPtr u8)
        (unsafe
          (ptr-cast (ptr-addr-of output) : (MutPtr u8)))]
      (begin
        (test-require-update
          (unsafe
            (sha.update-from-pointer!
              (&mut state)
              source
              (byte_buf.bytes-length input))))
        (test-require-finalize-into
          (unsafe
            (sha.consume-finalize-into! (&mut state) sink 64)))
        (let
          [actual : sha.Sha512Digest (sha.Sha512Digest output)]
          (test.assert-true
            (sha.digest-eq? (& actual) (& expected))
            "SHA-512 raw source/sink equivalence"))
        (test.assert-true state.finalized "SHA-512 consumed state poison")
        (test.assert-true
          (= (array-ref state.words 0) (cast 0 : u64))
          "SHA-512 consumed state wipe")
        (let
          [rejected-state : sha.Sha512State (sha.new)]
          [rejected-output : (Array u8 64) (init)]
          [rejected-sink : (MutPtr u8)
            (unsafe
              (ptr-cast (ptr-addr-of rejected-output) : (MutPtr u8)))]
          (begin
            (set! (array-ref rejected-output 0) (cast 165 : u8))
            (test-assert-output-error
              (unsafe
                (sha.consume-finalize-into!
                  (&mut rejected-state)
                  rejected-sink
                  63)))
            (test.assert-i64-eq
              (cast (array-ref rejected-output 0) : i64)
              165
              "SHA-512 rejected sink remains unchanged")
            (test.assert-true
              rejected-state.finalized
              "SHA-512 rejected sink still consumes state")))
        (let
          [null-sink-state : sha.Sha512State (sha.new)]
          (begin
            (test-assert-output-error
              (unsafe
                (sha.consume-finalize-into!
                  (&mut null-sink-state)
                  (ptr-null : (MutPtr u8))
                  64)))
            (test.assert-true
              null-sink-state.finalized
              "SHA-512 null sink still consumes state")))
        (let
          [invalid-source-state : sha.Sha512State (sha.new)]
          (begin
            (test-assert-source-error
              (unsafe
                (sha.update-from-pointer!
                  (&mut invalid-source-state)
                  (ptr-null : (Ptr u8))
                  1)))
            (test-assert-source-error
              (unsafe
                (sha.update-from-pointer!
                  (&mut invalid-source-state)
                  (ptr-null : (Ptr u8))
                  -1)))
            (test.assert-i64-eq
              invalid-source-state.block-length
              0
              "SHA-512 invalid source leaves state unchanged")))
        (let
          [empty-state : sha.Sha512State (sha.new)]
          (begin
            (test-require-update
              (unsafe
                (sha.update-from-pointer!
                  (&mut empty-state)
                  (ptr-null : (Ptr u8))
                  0)))
            (sha.wipe-state! (&mut empty-state))))))))

(cfg
  test
  (test
    crypto-sha512-length-and-lifecycle
    (begin
      (match (sha.length-add
        (cast 7 : u64)
        (cast 0xffffffffffffffff : u64)
        (cast 1 : u64))
        [(sha.Sha512LengthOk length)
          (begin
            (test.assert-true
              (= length.high (cast 8 : u64))
              "SHA-512 low-half carry high")
            (test.assert-true
              (= length.low (cast 0 : u64))
              "SHA-512 low-half carry low"))]
        [(sha.Sha512LengthErr _)
          (test.assert-true false "SHA-512 carry should be admitted")])
      (match (sha.length-add
        (sha.max-byte-length-high)
        (cast 0xfffffffffffffffe : u64)
        (cast 1 : u64))
        [(sha.Sha512LengthOk length)
          (test.assert-true
            (and
              (= length.high (sha.max-byte-length-high))
              (= length.low (cast 0xffffffffffffffff : u64)))
            "SHA-512 maximum byte length should be admitted")]
        [(sha.Sha512LengthErr _)
          (test.assert-true false "SHA-512 maximum should be admitted")])
      (test-assert-length-error
        (sha.length-add
          (sha.max-byte-length-high)
          (cast 0xffffffffffffffff : u64)
          (cast 1 : u64)))
      (let
        [state : sha.Sha512State (sha.new)]
        [one-byte : String "x"]
        (begin
          ; Synthetic valid bookkeeping exercises update admission at the
          ; FIPS limit without constructing a 2^125-byte input.
          (set! state.byte-length-high (sha.max-byte-length-high))
          (set! state.byte-length-low (cast 0xffffffffffffffff : u64))
          (set! state.block-length 127)
          (match (sha.update! (&mut state) (byte_buf.str-as-bytes (& one-byte)))
            [(sha.Sha512UpdateErr (sha.Sha512MessageTooLong _ _ _)) unit]
            [_
              (test.assert-true
                false
                "SHA-512 update should reject the first out-of-domain byte")])
          (test.assert-true
            (= state.byte-length-high (sha.max-byte-length-high))
            "SHA-512 rejected update preserves high length")
          (test.assert-true
            (= state.byte-length-low (cast 0xffffffffffffffff : u64))
            "SHA-512 rejected update preserves low length")
          (test.assert-i64-eq
            state.block-length
            127
            "SHA-512 rejected update preserves partial block length")))
      (let
        [block : (Array u8 128) (init)]
        (begin
          (sha.write-bit-length! (&mut block) (cast 1 : u64) (cast 2 : u64))
          (test.assert-i64-eq
            (cast (array-ref block 119) : i64)
            8
            "SHA-512 encoded high bit length")
          (test.assert-i64-eq
            (cast (array-ref block 127) : i64)
            16
            "SHA-512 encoded low bit length")))
      (let
        [state : sha.Sha512State (sha.new)]
        [empty : String ""]
        (begin
          (let
            [first : sha.Sha512Digest
              (test-require-finalize (sha.finalize! (&mut state)))]
            (begin
              (sha.wipe-digest! (&mut first))
              (test.assert-i64-eq
                (cast (sha.digest-byte (& first) 0) : i64)
                0
                "SHA-512 digest wipe")))
          (test-assert-finalized-update
            (sha.update! (&mut state) (byte_buf.str-as-bytes (& empty))))
          (test-assert-finalized-finalize (sha.finalize! (&mut state)))
          (sha.wipe-state! (&mut state))
          (test.assert-true state.finalized "SHA-512 state wipe poison")
          (test.assert-true
            (= (array-ref state.words 0) (cast 0 : u64))
            "SHA-512 state wipe words")
          (test.assert-i64-eq
            (cast (array-ref state.block 127) : i64)
            0
            "SHA-512 state wipe block"))))))