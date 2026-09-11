(cfg test (import stdlib.byte_buf))
(cfg test (import stdlib.crypto_sha256 as sha))
(cfg test (import stdlib.test))

;: Return a zero digest after recording an unexpected test failure.
(cfg
  test
  (define (test-zero-digest [message : String]) : sha.Sha256Digest
    (begin
      (test.assert-true false message)
      (sha.Sha256Digest (init)))))

;: Require one successful streaming update.
(cfg
  test
  (define (test-require-update [result : sha.Sha256UpdateResult]) : unit
    (match result
      [(sha.Sha256UpdateOk) unit]
      [(sha.Sha256UpdateErr _)
        (test.assert-true false "SHA-256 update should succeed")])))

;: Require one successful public finalization.
(cfg
  test
  (define (test-require-finalize [result : sha.Sha256FinalizeResult]) : sha.Sha256Digest
    (match result
      [(sha.Sha256FinalizeOk value) value]
      [(sha.Sha256FinalizeErr _)
        (test-zero-digest "SHA-256 finalization should succeed")])))

;: Hash one exact borrowed input.
(cfg
  test
  (define (test-digest [input : (& input bytes)]) : sha.Sha256Digest
    (test-require-finalize (sha.digest input))))

;: Assert one public preimage/digest pair.
(cfg
  test
  (define (test-assert-vector
    [input : (& input bytes)]
    [expected : String]
    [message : String]) : unit
    (let
      [result : sha.Sha256Digest (test-digest input)]
      [actual : String (sha.to-hex (& result))]
      (begin
        (test.assert-i64-eq
          (array-length (sha.digest-bytes (& result)))
          32
          "SHA-256 digest width")
        (test.assert-i64-eq
          (string-length (& actual))
          64
          "SHA-256 hexadecimal width")
        (test.assert-string-eq (& actual) (& expected) message)))))

;: Assert one borrowed text vector.
(cfg
  test
  (define (test-assert-text-vector
    [text : String]
    [expected : String]
    [message : String]) : unit
    (test-assert-vector (byte_buf.str-as-bytes (& text)) expected message)))

;: Construct `count` copies of one exact byte.
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

;: Assert one repeated-byte boundary vector.
(cfg
  test
  (define (test-assert-repeated-vector [count : i64] [expected : String]) : unit
    (let
      [buf : byte_buf.ByteBuf (test-repeated-bytes count (cast 'a' : u8))]
      (test-assert-vector
        (byte_buf.as-bytes (& buf))
        expected
        "SHA-256 padding boundary"))))

;: Check all two-chunk splits, explicit empty updates, and byte-at-a-time input.
(cfg
  test
  (define (test-streaming-splits [input : (& input bytes)]) : unit
    (let
      [expected : sha.Sha256Digest (test-digest input)]
      [input-length : i64 (byte_buf.bytes-length input)]
      [split : i64 0]
      (begin
        (while (<= split input-length)
          (let
            [state : sha.Sha256State (sha.new)]
            [left : (& input bytes) (byte_buf.bytes-slice-view input 0 split)]
            [right : (& input bytes)
              (byte_buf.bytes-slice-view input split (- input-length split))]
            (begin
              (test-require-update (sha.update! (&mut state) left))
              (test-require-update
                (sha.update! (&mut state) (byte_buf.bytes-slice-view input 0 0)))
              (test-require-update (sha.update! (&mut state) right))
              (let
                [actual : sha.Sha256Digest
                  (test-require-finalize (sha.finalize! (&mut state)))]
                (test.assert-true
                  (sha.digest-eq? (& actual) (& expected))
                  "SHA-256 split digest"))
              (set! split (+ split 1)))))
        (let
          [state : sha.Sha256State (sha.new)]
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
              [actual : sha.Sha256Digest
                (test-require-finalize (sha.finalize! (&mut state)))]
              (test.assert-true
                (sha.digest-eq? (& actual) (& expected))
                "SHA-256 byte-at-a-time digest"))))))))

;: Require one lifecycle error from an update after finalization.
(cfg
  test
  (define (test-assert-finalized-update [result : sha.Sha256UpdateResult]) : unit
    (match result
      [(sha.Sha256UpdateErr (sha.Sha256Finalized)) unit]
      [_ (test.assert-true false "expected finalized SHA-256 update error")])))

;: Require one lifecycle error from repeated finalization.
(cfg
  test
  (define (test-assert-finalized-finalize [result : sha.Sha256FinalizeResult]) : unit
    (match result
      [(sha.Sha256FinalizeErr (sha.Sha256Finalized)) unit]
      [_
        (test.assert-true false "expected finalized SHA-256 finalization error")])))

;: Require one checked total-length overflow.
(cfg
  test
  (define (test-assert-length-error [result : sha.Sha256LengthResult]) : unit
    (match result
      [(sha.Sha256LengthErr (sha.Sha256MessageTooLong _ _)) unit]
      [_ (test.assert-true false "expected SHA-256 length error")])))

;: Require a raw-source validation failure.
(cfg
  test
  (define (test-assert-source-error [result : sha.Sha256UpdateResult]) : unit
    (match result
      [(sha.Sha256UpdateErr (sha.Sha256InvalidSource)) unit]
      [(sha.Sha256UpdateErr (sha.Sha256InvalidSourceLength _)) unit]
      [_ (test.assert-true false "expected SHA-256 source error")])))

;: Require an invalid public state error.
(cfg
  test
  (define (test-assert-state-error [result : sha.Sha256UpdateResult]) : unit
    (match result
      [(sha.Sha256UpdateErr (sha.Sha256InvalidState)) unit]
      [_ (test.assert-true false "expected SHA-256 state error")])))

;: Require an exact-output validation failure.
(cfg
  test
  (define (test-assert-output-error [result : sha.Sha256FinalizeIntoResult]) : unit
    (match result
      [(sha.Sha256FinalizeIntoErr (sha.Sha256InvalidOutput)) unit]
      [(sha.Sha256FinalizeIntoErr (sha.Sha256InvalidOutputLength _)) unit]
      [_ (test.assert-true false "expected SHA-256 output error")])))

;: Require a duplicate consumed-state finalization error.
(cfg
  test
  (define (test-assert-finalize-into-closed
    [result : sha.Sha256FinalizeIntoResult]) : unit
    (match result
      [(sha.Sha256FinalizeIntoErr (sha.Sha256Finalized)) unit]
      [_ (test.assert-true false "expected closed SHA-256 sink error")])))

;: Require successful finalization through the exact raw sink.
(cfg
  test
  (define (test-require-finalize-into [result : sha.Sha256FinalizeIntoResult]) : unit
    (match result
      [(sha.Sha256FinalizeIntoOk) unit]
      [(sha.Sha256FinalizeIntoErr _)
        (test.assert-true false "SHA-256 sink finalization should succeed")])))

(cfg
  test
  (test
    crypto-sha256-fips-vectors
    (begin
      (test-assert-text-vector
        ""
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        "SHA-256 empty vector")
      (test-assert-text-vector
        "abc"
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        "SHA-256 abc vector")
      (test-assert-text-vector
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        "SHA-256 long FIPS vector"))))

(cfg
  test
  (test
    crypto-sha256-padding-boundaries
    (begin
      (test-assert-repeated-vector
        55
        "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
      (test-assert-repeated-vector
        56
        "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
      (test-assert-repeated-vector
        63
        "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34")
      (test-assert-repeated-vector
        64
        "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
      (test-assert-repeated-vector
        65
        "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0")
      (test-assert-repeated-vector
        128
        "6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e"))))

(cfg
  test
  (test
    crypto-sha256-streaming
    (let
      [empty : String ""]
      [abc : String "abc"]
      [many : byte_buf.ByteBuf (test-repeated-bytes 130 (cast 'z' : u8))]
      (begin
        (test-streaming-splits (byte_buf.str-as-bytes (& empty)))
        (test-streaming-splits (byte_buf.str-as-bytes (& abc)))
        (test-streaming-splits (byte_buf.as-bytes (& many)))))))

(cfg
  test
  (test
    crypto-sha256-million-a
    (let
      [chunk : byte_buf.ByteBuf (test-repeated-bytes 1000 (cast 'a' : u8))]
      [state : sha.Sha256State (sha.new)]
      [count : i64 0]
      (begin
        (while (< count 1000)
          (begin
            (test-require-update
              (sha.update! (&mut state) (byte_buf.as-bytes (& chunk))))
            (set! count (+ count 1))))
        (let
          [result : sha.Sha256Digest
            (test-require-finalize (sha.finalize! (&mut state)))]
          [actual : String (sha.to-hex (& result))]
          [expected : String
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"]
          (test.assert-string-eq
            (& actual)
            (& expected)
            "SHA-256 million-a vector"))))))

(cfg
  test
  (test
    crypto-sha256-length-and-lifecycle
    (begin
      (match (sha.length-add
        (- (sha.max-byte-length) (cast 1 : u64))
        (cast 1 : u64))
        [(sha.Sha256LengthOk length)
          (test.assert-true
            (= length (sha.max-byte-length))
            "SHA-256 maximum byte length should be admitted")]
        [(sha.Sha256LengthErr _)
          (test.assert-true false "SHA-256 maximum should be admitted")])
      (test-assert-length-error
        (sha.length-add (sha.max-byte-length) (cast 1 : u64)))
      (test-assert-length-error
        (sha.length-add (cast 0xffffffffffffffff : u64) (cast 1 : u64)))
      (let
        [state : sha.Sha256State (sha.new)]
        [one-byte : String "x"]
        (begin
          ; Synthetic valid bookkeeping reaches the FIPS limit without a huge
          ; allocation; max-byte-length modulo 64 is 63.
          (set! state.byte-length (sha.max-byte-length))
          (set! state.block-length 63)
          (match (sha.update! (&mut state) (byte_buf.str-as-bytes (& one-byte)))
            [(sha.Sha256UpdateErr (sha.Sha256MessageTooLong _ _)) unit]
            [_
              (test.assert-true
                false
                "SHA-256 update should reject the first out-of-domain byte")])
          (test.assert-true
            (= state.byte-length (sha.max-byte-length))
            "SHA-256 rejected update preserves length")
          (test.assert-i64-eq
            state.block-length
            63
            "SHA-256 rejected update preserves block cursor")))
      (let
        [invalid : sha.Sha256State (sha.new)]
        [empty : String ""]
        (begin
          (set! invalid.block-length 1)
          (test-assert-state-error
            (sha.update! (&mut invalid) (byte_buf.str-as-bytes (& empty))))
          (test.assert-i64-eq
            invalid.block-length
            1
            "SHA-256 invalid state remains unchanged")))
      (let
        [block : (Array u8 64) (init)]
        (begin
          (sha.write-bit-length! (&mut block) (cast 1 : u64))
          (test.assert-i64-eq
            (cast (array-ref block 62) : i64)
            0
            "SHA-256 encoded bit-length high byte")
          (test.assert-i64-eq
            (cast (array-ref block 63) : i64)
            8
            "SHA-256 encoded bit-length low byte")))
      (let
        [state : sha.Sha256State (sha.new)]
        [empty : String ""]
        (begin
          (let
            [first : sha.Sha256Digest
              (test-require-finalize (sha.finalize! (&mut state)))]
            (begin
              (sha.wipe-digest! (&mut first))
              (test.assert-i64-eq
                (cast (sha.digest-byte (& first) 0) : i64)
                0
                "SHA-256 digest wipe")))
          (test.assert-true state.finalized "SHA-256 finalized state poison")
          (test.assert-true
            (= state.byte-length (cast 0 : u64))
            "SHA-256 finalized state clears length")
          (test.assert-true
            (= (array-ref state.words 0) (cast 0 : u32))
            "SHA-256 finalized state clears words")
          (test-assert-finalized-update
            (sha.update! (&mut state) (byte_buf.str-as-bytes (& empty))))
          (test-assert-finalized-finalize (sha.finalize! (&mut state))))))))

(cfg
  test
  (test
    crypto-sha256-scoped-pointer-and-exact-sink
    (let
      [text : String
        "public SHA-256 equivalence input crossing one compression block..............."]
      [input : (& text bytes) (byte_buf.str-as-bytes (& text))]
      [expected : sha.Sha256Digest (test-digest input)]
      [state : sha.Sha256State (sha.new)]
      [output : (Array u8 32) (init)]
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
            (sha.consume-finalize-into! (&mut state) sink 32)))
        (let
          [actual : sha.Sha256Digest (sha.Sha256Digest output)]
          (test.assert-true
            (sha.digest-eq? (& actual) (& expected))
            "SHA-256 raw source/sink equivalence"))
        (test.assert-true state.finalized "SHA-256 consumed state poison")
        (test.assert-true
          (= (array-ref state.words 0) (cast 0 : u32))
          "SHA-256 consumed state wipe")
        (let
          [duplicate-output : (Array u8 32) (init)]
          [duplicate-sink : (MutPtr u8)
            (unsafe
              (ptr-cast (ptr-addr-of duplicate-output) : (MutPtr u8)))]
          (begin
            (set! (array-ref duplicate-output 0) (cast 165 : u8))
            (test-assert-finalize-into-closed
              (unsafe
                (sha.consume-finalize-into! (&mut state) duplicate-sink 32)))
            (test.assert-i64-eq
              (cast (array-ref duplicate-output 0) : i64)
              165
              "SHA-256 duplicate finalize leaves sink unchanged")))
        (let
          [rejected-state : sha.Sha256State (sha.new)]
          [rejected-output : (Array u8 33) (init)]
          [rejected-sink : (MutPtr u8)
            (unsafe
              (ptr-cast (ptr-addr-of rejected-output) : (MutPtr u8)))]
          (begin
            (set! (array-ref rejected-output 0) (cast 60 : u8))
            (set! (array-ref rejected-output 32) (cast 195 : u8))
            (test-assert-output-error
              (unsafe
                (sha.consume-finalize-into!
                  (&mut rejected-state)
                  rejected-sink
                  33)))
            (test.assert-i64-eq
              (cast (array-ref rejected-output 0) : i64)
              60
              "SHA-256 rejected sink start unchanged")
            (test.assert-i64-eq
              (cast (array-ref rejected-output 32) : i64)
              195
              "SHA-256 rejected sink end unchanged")
            (test.assert-true
              rejected-state.finalized
              "SHA-256 rejected sink consumes state")))
        (let
          [null-sink-state : sha.Sha256State (sha.new)]
          (begin
            (test-assert-output-error
              (unsafe
                (sha.consume-finalize-into!
                  (&mut null-sink-state)
                  (ptr-null : (MutPtr u8))
                  32)))
            (test.assert-true
              null-sink-state.finalized
              "SHA-256 null sink consumes state")))
        (let
          [invalid-source-state : sha.Sha256State (sha.new)]
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
              "SHA-256 invalid source leaves state unchanged")))
        (let
          [empty-state : sha.Sha256State (sha.new)]
          (begin
            (test-require-update
              (unsafe
                (sha.update-from-pointer!
                  (&mut empty-state)
                  (ptr-null : (Ptr u8))
                  0)))
            (sha.wipe-state! (&mut empty-state))))))))