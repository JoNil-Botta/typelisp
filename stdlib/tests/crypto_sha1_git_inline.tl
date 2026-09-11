(cfg test (import stdlib.byte_buf))
(cfg test (import stdlib.crypto_sha1_git as sha))
(cfg test (import stdlib.test))

;: Return a zero digest after recording an unexpected test failure.
(cfg
  test
  (define (test-zero-digest [message : String]) : sha.GitSha1Digest
    (begin
      (test.assert-true false message)
      (sha.GitSha1Digest (init)))))

;: Require one successful streaming update.
(cfg
  test
  (define (test-require-update [result : sha.GitSha1UpdateResult]) : unit
    (match result
      [(sha.GitSha1UpdateOk) unit]
      [(sha.GitSha1UpdateErr _)
        (test.assert-true false "Git SHA-1 update should succeed")])))

;: Extract one successful public digest.
(cfg
  test
  (define (test-require-finalize [result : sha.GitSha1FinalizeResult]) : sha.GitSha1Digest
    (match result
      [(sha.GitSha1FinalizeOk value) value]
      [(sha.GitSha1FinalizeErr _)
        (test-zero-digest "Git SHA-1 finalization should succeed")])))

;: Hash one exact borrowed compatibility preimage.
(cfg
  test
  (define (test-digest [input : (& input bytes)]) : sha.GitSha1Digest
    (test-require-finalize (sha.git-digest input))))

;: Assert one public preimage/digest pair.
(cfg
  test
  (define (test-assert-vector
    [input : (& input bytes)]
    [expected : String]
    [message : String]) : unit
    (let
      [result : sha.GitSha1Digest (test-digest input)]
      [actual : String (sha.to-hex (& result))]
      (begin
        (test.assert-i64-eq
          (array-length (sha.digest-bytes (& result)))
          20
          "Git SHA-1 digest width")
        (test.assert-i64-eq
          (string-length (& actual))
          40
          "Git SHA-1 hexadecimal width")
        (test.assert-string-eq (& actual) (& expected) message)))))

;: Assert one borrowed text vector.
(cfg
  test
  (define (test-assert-text-vector
    [text : String]
    [expected : String]
    [message : String]) : unit
    (test-assert-vector (byte_buf.str-as-bytes (& text)) expected message)))

;: Construct `count` repeated bytes.
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

;: Convert one test-only lowercase hexadecimal byte string to binary.
(cfg
  test
  (define (test-hex-nibble [value : u8]) : u8
    (if (and (>= value (cast '0' : u8)) (<= value (cast '9' : u8)))
      (- value (cast '0' : u8))
      (+ (- value (cast 'a' : u8)) (cast 10 : u8)))))

(cfg
  test
  (define (test-bytes-from-hex [hex : String]) : byte_buf.ByteBuf
    (let
      [source : (& hex bytes) (byte_buf.str-as-bytes (& hex))]
      [count : i64 (/ (byte_buf.bytes-length source) 2)]
      [result : byte_buf.ByteBuf
        (byte_buf.from-array (__tl_make-array u8 count))]
      [index : i64 0]
      (begin
        (while (< index count)
          (let
            [high : u8
              (test-hex-nibble (byte_buf.bytes-ref source (* index 2)))]
            [low : u8
              (test-hex-nibble (byte_buf.bytes-ref source (+ (* index 2) 1)))]
            (begin
              (set!
                result
                (byte_buf.set! result index (+ (shl high (cast 4 : u64)) low)))
              (set! index (+ index 1)))))
        result))))

;: Check every two-chunk split, explicit empty chunks, and byte-at-a-time input.
(cfg
  test
  (define (test-streaming-splits [input : (& input bytes)]) : unit
    (let
      [expected : sha.GitSha1Digest (test-digest input)]
      [input-length : i64 (byte_buf.bytes-length input)]
      [split : i64 0]
      (begin
        (while (<= split input-length)
          (let
            [state : sha.GitSha1State (sha.new)]
            [left : (& input bytes) (byte_buf.bytes-slice-view input 0 split)]
            [right : (& input bytes)
              (byte_buf.bytes-slice-view input split (- input-length split))]
            (begin
              (test-require-update (sha.update! (&mut state) left))
              (test-require-update
                (sha.update! (&mut state) (byte_buf.bytes-slice-view input 0 0)))
              (test-require-update (sha.update! (&mut state) right))
              (let
                [actual : sha.GitSha1Digest
                  (test-require-finalize (sha.finalize! (&mut state)))]
                (test.assert-true
                  (sha.digest-eq? (& actual) (& expected))
                  "Git SHA-1 split digest"))
              (set! split (+ split 1)))))
        (let
          [state : sha.GitSha1State (sha.new)]
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
              [actual : sha.GitSha1Digest
                (test-require-finalize (sha.finalize! (&mut state)))]
              (test.assert-true
                (sha.digest-eq? (& actual) (& expected))
                "Git SHA-1 byte-at-a-time digest"))))))))

;: Build a Git object hash preimage: ASCII header, NUL, exact content bytes.
(cfg
  test
  (define (test-git-object-preimage
    [header : String]
    [content : (& content bytes)]) : byte_buf.ByteBuf
    (let
      [result : byte_buf.ByteBuf
        (byte_buf.push
          (byte_buf.append-string (byte_buf.new) header)
          (cast 0 : u8))]
      (byte_buf.append-bytes result content))))

;: Assert one independently generated Git object or pack fixture.
(cfg
  test
  (define (test-assert-git-fixture
    [input : (& input bytes)]
    [expected : String]
    [message : String]) : unit
    (begin
      (test-assert-vector input expected message)
      (test-streaming-splits input))))

;: Require the common finalized-state update error.
(cfg
  test
  (define (test-assert-finalized-update [result : sha.GitSha1UpdateResult]) : unit
    (match result
      [(sha.GitSha1UpdateErr (sha.GitSha1Finalized)) unit]
      [_ (test.assert-true false "expected finalized Git SHA-1 update error")])))

;: Require the common finalized-state finalization error.
(cfg
  test
  (define (test-assert-finalized-finalize [result : sha.GitSha1FinalizeResult]) : unit
    (match result
      [(sha.GitSha1FinalizeErr (sha.GitSha1Finalized)) unit]
      [_
        (test.assert-true
          false
          "expected finalized Git SHA-1 finalization error")])))

;: Require one checked total-length overflow.
(cfg
  test
  (define (test-assert-length-error [result : sha.GitSha1LengthResult]) : unit
    (match result
      [(sha.GitSha1LengthErr (sha.GitSha1MessageTooLong _ _)) unit]
      [_ (test.assert-true false "expected Git SHA-1 length error")])))

;: Require a raw-source validation error.
(cfg
  test
  (define (test-assert-source-error [result : sha.GitSha1UpdateResult]) : unit
    (match result
      [(sha.GitSha1UpdateErr (sha.GitSha1InvalidSource)) unit]
      [(sha.GitSha1UpdateErr (sha.GitSha1InvalidSourceLength _)) unit]
      [_ (test.assert-true false "expected Git SHA-1 source error")])))

;: Require an exact-output validation error.
(cfg
  test
  (define (test-assert-output-error [result : sha.GitSha1FinalizeIntoResult]) : unit
    (match result
      [(sha.GitSha1FinalizeIntoErr (sha.GitSha1InvalidOutput)) unit]
      [(sha.GitSha1FinalizeIntoErr (sha.GitSha1InvalidOutputLength _)) unit]
      [_ (test.assert-true false "expected Git SHA-1 output error")])))

;: Require a duplicate/closed raw finalization error.
(cfg
  test
  (define (test-assert-finalize-into-closed
    [result : sha.GitSha1FinalizeIntoResult]) : unit
    (match result
      [(sha.GitSha1FinalizeIntoErr (sha.GitSha1Finalized)) unit]
      [_ (test.assert-true false "expected closed Git SHA-1 sink error")])))

;: Require one successful exact-sink finalization.
(cfg
  test
  (define (test-require-finalize-into [result : sha.GitSha1FinalizeIntoResult]) : unit
    (match result
      [(sha.GitSha1FinalizeIntoOk) unit]
      [(sha.GitSha1FinalizeIntoErr _)
        (test.assert-true false "Git SHA-1 sink finalization should succeed")])))

(cfg
  test
  (test
    crypto-sha1-git-fips-vectors
    (begin
      (test-assert-text-vector
        ""
        "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        "Git SHA-1 FIPS empty vector")
      (test-assert-text-vector
        "abc"
        "a9993e364706816aba3e25717850c26c9cd0d89d"
        "Git SHA-1 FIPS abc vector")
      (test-assert-text-vector
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
        "Git SHA-1 FIPS multi-block vector"))))

(cfg
  test
  (test
    crypto-sha1-git-padding-boundaries
    (let
      [a55 : byte_buf.ByteBuf (test-repeated-bytes 55 (cast 'a' : u8))]
      [a56 : byte_buf.ByteBuf (test-repeated-bytes 56 (cast 'a' : u8))]
      [a63 : byte_buf.ByteBuf (test-repeated-bytes 63 (cast 'a' : u8))]
      [a64 : byte_buf.ByteBuf (test-repeated-bytes 64 (cast 'a' : u8))]
      [a65 : byte_buf.ByteBuf (test-repeated-bytes 65 (cast 'a' : u8))]
      (begin
        (test-assert-vector
          (byte_buf.as-bytes (& a55))
          "c1c8bbdc22796e28c0e15163d20899b65621d65a"
          "Git SHA-1 55-byte boundary")
        (test-assert-vector
          (byte_buf.as-bytes (& a56))
          "c2db330f6083854c99d4b5bfb6e8f29f201be699"
          "Git SHA-1 56-byte boundary")
        (test-assert-vector
          (byte_buf.as-bytes (& a63))
          "03f09f5b158a7a8cdad920bddc29b81c18a551f5"
          "Git SHA-1 63-byte boundary")
        (test-assert-vector
          (byte_buf.as-bytes (& a64))
          "0098ba824b5c16427bd7a1122a5a442a25ec644d"
          "Git SHA-1 64-byte boundary")
        (test-assert-vector
          (byte_buf.as-bytes (& a65))
          "11655326c708d70319be2610e8a57d9a5b959d3b"
          "Git SHA-1 65-byte boundary")
        (test-streaming-splits (byte_buf.as-bytes (& a55)))
        (test-streaming-splits (byte_buf.as-bytes (& a56)))
        (test-streaming-splits (byte_buf.as-bytes (& a63)))
        (test-streaming-splits (byte_buf.as-bytes (& a64)))
        (test-streaming-splits (byte_buf.as-bytes (& a65)))))))

(cfg
  test
  (test
    crypto-sha1-git-million-a
    (let
      [chunk : byte_buf.ByteBuf (test-repeated-bytes 1000 (cast 'a' : u8))]
      [state : sha.GitSha1State (sha.new)]
      [count : i64 0]
      (begin
        (while (< count 1000)
          (begin
            (test-require-update
              (sha.update! (&mut state) (byte_buf.as-bytes (& chunk))))
            (set! count (+ count 1))))
        (let
          [result : sha.GitSha1Digest
            (test-require-finalize (sha.finalize! (&mut state)))]
          [actual : String (sha.to-hex (& result))]
          [expected : String "34aa973cd4c4daa4f61eeb2bdbad27316534016f"]
          (test.assert-string-eq
            (& actual)
            (& expected)
            "Git SHA-1 million-a vector"))))))

(cfg
  test
  (test
    crypto-sha1-git-object-and-pack-fixtures
    (let
      [blob-content : String "hello\n"]
      [blob : byte_buf.ByteBuf
        (test-git-object-preimage
          "blob 6"
          (byte_buf.str-as-bytes (& blob-content)))]
      [tree-content : byte_buf.ByteBuf
        (test-bytes-from-hex
          "3130303634342068656c6c6f00ce013625030ba8dba906f756967f9e9ca394464a")]
      [tree : byte_buf.ByteBuf
        (test-git-object-preimage
          "tree 33"
          (byte_buf.as-bytes (& tree-content)))]
      [commit-content : String
        "tree b4d01e9b0c4a9356736dfddf8830ba9a54f5271c\nauthor A U Thor <author@example.com> 0 +0000\ncommitter A U Thor <author@example.com> 0 +0000\n\ninitial\n"]
      [commit : byte_buf.ByteBuf
        (test-git-object-preimage
          "commit 148"
          (byte_buf.str-as-bytes (& commit-content)))]
      [tag-content : String
        "object d6881e70cb3a878a5e96e8f38a6063e2ed786786\ntype commit\ntag v1.0\ntagger A U Thor <author@example.com> 0 +0000\n\nrelease\n"]
      [tag : byte_buf.ByteBuf
        (test-git-object-preimage
          "tag 123"
          (byte_buf.str-as-bytes (& tag-content)))]
      [pack-payload : byte_buf.ByteBuf
        (test-bytes-from-hex
          "5041434b000000020000000136789ccb48cdc9c9e70200084b021f")]
      (begin
        ; Object IDs were produced by git hash-object/mktree using Git 2.51.
        (test-assert-git-fixture
          (byte_buf.as-bytes (& blob))
          "ce013625030ba8dba906f756967f9e9ca394464a"
          "Git blob object ID")
        (test-assert-git-fixture
          (byte_buf.as-bytes (& tree))
          "b4d01e9b0c4a9356736dfddf8830ba9a54f5271c"
          "Git tree object ID")
        (test-assert-git-fixture
          (byte_buf.as-bytes (& commit))
          "d6881e70cb3a878a5e96e8f38a6063e2ed786786"
          "Git commit object ID")
        (test-assert-git-fixture
          (byte_buf.as-bytes (& tag))
          "00347d6e2d4f3ce51b4bf757d5bbd8863a171611"
          "Git tag object ID")
        ; This is the exact pre-trailer payload of Git's one-blob pack.
        (test-assert-git-fixture
          (byte_buf.as-bytes (& pack-payload))
          "de0412401f4a9e5f05411f44eaf9c86d46096746"
          "Git pack trailer")))))

(cfg
  test
  (test
    crypto-sha1-git-length-and-lifecycle
    (begin
      (match (sha.length-add (cast 0xffffffff : u64) (cast 2 : u64))
        [(sha.GitSha1LengthOk length)
          (test.assert-true
            (= length (cast 0x100000001 : u64))
            "Git SHA-1 length crosses 32-bit range")]
        [(sha.GitSha1LengthErr _)
          (test.assert-true false "Git SHA-1 32-bit crossing should pass")])
      (match (sha.length-add
        (- (sha.max-byte-length) (cast 1 : u64))
        (cast 1 : u64))
        [(sha.GitSha1LengthOk length)
          (test.assert-true
            (= length (sha.max-byte-length))
            "Git SHA-1 maximum byte length admitted")]
        [(sha.GitSha1LengthErr _)
          (test.assert-true false "Git SHA-1 maximum should pass")])
      (test-assert-length-error
        (sha.length-add (sha.max-byte-length) (cast 1 : u64)))
      (let
        [state : sha.GitSha1State (sha.new)]
        [two-bytes : String "xx"]
        (begin
          ; Synthetic valid bookkeeping avoids constructing a 4 GiB input.
          (set! state.byte-length (cast 0xffffffff : u64))
          (set! state.block-length 63)
          (test-require-update
            (sha.update! (&mut state) (byte_buf.str-as-bytes (& two-bytes))))
          (test.assert-true
            (= state.byte-length (cast 0x100000001 : u64))
            "Git SHA-1 streaming counter crosses 32-bit range")
          (test.assert-i64-eq
            state.block-length
            1
            "Git SHA-1 32-bit crossing retains remainder")
          (sha.wipe-state! (&mut state))))
      (let
        [state : sha.GitSha1State (sha.new)]
        [one-byte : String "x"]
        (begin
          (set! state.byte-length (sha.max-byte-length))
          (set! state.block-length 63)
          (match (sha.update! (&mut state) (byte_buf.str-as-bytes (& one-byte)))
            [(sha.GitSha1UpdateErr (sha.GitSha1MessageTooLong _ _)) unit]
            [_
              (test.assert-true
                false
                "Git SHA-1 update should reject domain overflow")])
          (test.assert-true
            (= state.byte-length (sha.max-byte-length))
            "Git SHA-1 rejected update preserves length")
          (test.assert-i64-eq
            state.block-length
            63
            "Git SHA-1 rejected update preserves block")
          (sha.wipe-state! (&mut state))))
      (let
        [block : (Array u8 64) (init)]
        (begin
          (sha.write-bit-length! (&mut block) (cast 0x100000002 : u64))
          (test.assert-i64-eq
            (cast (array-ref block 59) : i64)
            8
            "Git SHA-1 encoded high 32-bit crossing")
          (test.assert-i64-eq
            (cast (array-ref block 63) : i64)
            16
            "Git SHA-1 encoded low bit count")))
      (let
        [state : sha.GitSha1State (sha.new)]
        [empty : String ""]
        (begin
          (let
            [first : sha.GitSha1Digest
              (test-require-finalize (sha.finalize! (&mut state)))]
            (begin
              (sha.wipe-digest! (&mut first))
              (test.assert-i64-eq
                (cast (sha.digest-byte (& first) 0) : i64)
                0
                "Git SHA-1 digest wipe")))
          (test.assert-true
            (not state.open)
            "Git SHA-1 finalized state close marker")
          (test.assert-true
            (= state.byte-length (cast 0 : u64))
            "Git SHA-1 finalized state clears length")
          (test.assert-true
            (= (array-ref state.words 0) (cast 0 : u32))
            "Git SHA-1 finalized state clears words")
          (test.assert-i64-eq
            (cast (array-ref state.block 63) : i64)
            0
            "Git SHA-1 finalized state clears block")
          (test-assert-finalized-update
            (sha.update! (&mut state) (byte_buf.str-as-bytes (& empty))))
          (test-assert-finalized-finalize (sha.finalize! (&mut state))))))))

(cfg
  test
  (test
    crypto-sha1-git-scoped-pointer-and-exact-sink
    (let
      [text : String
        "public Git compatibility preimage crossing one SHA-1 block........................"]
      [input : (& text bytes) (byte_buf.str-as-bytes (& text))]
      [expected : sha.GitSha1Digest (test-digest input)]
      [state : sha.GitSha1State (sha.new)]
      [output : (Array u8 20) (init)]
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
            (sha.consume-finalize-into! (&mut state) sink 20)))
        (let
          [actual : sha.GitSha1Digest (sha.GitSha1Digest output)]
          (test.assert-true
            (sha.digest-eq? (& actual) (& expected))
            "Git SHA-1 raw source/sink equivalence"))
        (test.assert-true
          (not state.open)
          "Git SHA-1 consumed state close marker")
        (test.assert-true
          (= (array-ref state.words 0) (cast 0 : u32))
          "Git SHA-1 consumed state wipe")
        (let
          [duplicate-output : (Array u8 20) (init)]
          [duplicate-sink : (MutPtr u8)
            (unsafe
              (ptr-cast (ptr-addr-of duplicate-output) : (MutPtr u8)))]
          (begin
            (set! (array-ref duplicate-output 0) (cast 165 : u8))
            (test-assert-finalize-into-closed
              (unsafe
                (sha.consume-finalize-into! (&mut state) duplicate-sink 20)))
            (test.assert-i64-eq
              (cast (array-ref duplicate-output 0) : i64)
              165
              "Git SHA-1 duplicate finalize leaves sink unchanged")))
        (let
          [rejected-state : sha.GitSha1State (sha.new)]
          [rejected-output : (Array u8 20) (init)]
          [rejected-sink : (MutPtr u8)
            (unsafe
              (ptr-cast (ptr-addr-of rejected-output) : (MutPtr u8)))]
          (begin
            (set! (array-ref rejected-output 0) (cast 165 : u8))
            (set! (array-ref rejected-output 19) (cast 90 : u8))
            (test-assert-output-error
              (unsafe
                (sha.consume-finalize-into!
                  (&mut rejected-state)
                  rejected-sink
                  19)))
            (test.assert-i64-eq
              (cast (array-ref rejected-output 0) : i64)
              165
              "Git SHA-1 undersized sink start unchanged")
            (test.assert-i64-eq
              (cast (array-ref rejected-output 19) : i64)
              90
              "Git SHA-1 undersized sink end unchanged")
            (test.assert-true
              (not rejected-state.open)
              "Git SHA-1 rejected sink consumes state")))
        (let
          [oversized-state : sha.GitSha1State (sha.new)]
          [oversized-output : (Array u8 21) (init)]
          [oversized-sink : (MutPtr u8)
            (unsafe
              (ptr-cast (ptr-addr-of oversized-output) : (MutPtr u8)))]
          (begin
            (set! (array-ref oversized-output 0) (cast 60 : u8))
            (set! (array-ref oversized-output 20) (cast 195 : u8))
            (test-assert-output-error
              (unsafe
                (sha.consume-finalize-into!
                  (&mut oversized-state)
                  oversized-sink
                  21)))
            (test.assert-i64-eq
              (cast (array-ref oversized-output 0) : i64)
              60
              "Git SHA-1 oversized sink start unchanged")
            (test.assert-i64-eq
              (cast (array-ref oversized-output 20) : i64)
              195
              "Git SHA-1 oversized sink end unchanged")
            (test.assert-true
              (not oversized-state.open)
              "Git SHA-1 oversized sink consumes state")))
        (let
          [null-sink-state : sha.GitSha1State (sha.new)]
          (begin
            (test-assert-output-error
              (unsafe
                (sha.consume-finalize-into!
                  (&mut null-sink-state)
                  (ptr-null : (MutPtr u8))
                  20)))
            (test.assert-true
              (not null-sink-state.open)
              "Git SHA-1 null sink consumes state")))
        (let
          [invalid-source-state : sha.GitSha1State (sha.new)]
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
              "Git SHA-1 invalid source leaves state unchanged")))
        (let
          [empty-state : sha.GitSha1State (sha.new)]
          (begin
            (test-require-update
              (unsafe
                (sha.update-from-pointer!
                  (&mut empty-state)
                  (ptr-null : (Ptr u8))
                  0)))
            (sha.wipe-state! (&mut empty-state))))))))