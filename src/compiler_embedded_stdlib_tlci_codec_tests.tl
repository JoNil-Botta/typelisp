;; Focused malformed-frame coverage for the TLCI-only deployment envelope.
(import compiler_embedded_stdlib_tlci_codec as codec)
(import stdlib.array)
(import stdlib.string)

(define (tlci-codec-test-write-i64-le!
  [payload : (&mut payload (__tl_dyn-array u8))]
  [start : i64]
  [value : i64]) : unit
  (let
    [index : i64 0]
    (while (< index 8)
      (begin
        (set!
          (array-ref payload (+ start index))
          (cast (bit-and (shr value (* index 8)) 255) : u8))
        (set! index (+ index 1))))))

(define (tlci-codec-test-base-payload [raw-len : i64] [bit-len : i64]) : (__tl_dyn-array
    u8)
  (let
    [prefix : String (codec.compiler-embedded-stdlib-tlci-codec-prefix)]
    [prefix-len : i64 (string.string-length prefix)]
    [bit-bytes : i64
      (+
        (/ bit-len 8)
        (if (= (% bit-len 8) 0)
          0
          1))]
    [payload : (__tl_dyn-array u8)
      (array.make-array u8 (+ prefix-len (+ 16 (+ 4369 bit-bytes))))]
    [index : i64 0]
    (begin
      (while (< index prefix-len)
        (begin
          (set!
            (array-ref payload index)
            (cast (string.string-ref prefix index) : u8))
          (set! index (+ index 1))))
      (tlci-codec-test-write-i64-le! (&mut payload) prefix-len raw-len)
      (tlci-codec-test-write-i64-le! (&mut payload) (+ prefix-len 8) bit-len)
      payload)))

(define (tlci-codec-test-main-start) : i64
  (+
    (string.string-length (codec.compiler-embedded-stdlib-tlci-codec-prefix))
    16))

(define (tlci-codec-test-distance-start) : i64
  (+ (tlci-codec-test-main-start) 257))

(define (tlci-codec-test-length-start) : i64
  (+ (tlci-codec-test-distance-start) 4096))

(define (tlci-codec-test-match-payload
  [raw-len : i64]
  [bit-len : i64]
  [first : i64]
  [second : i64]) : (__tl_dyn-array u8)
  (let
    [payload : (__tl_dyn-array u8)
      (tlci-codec-test-base-payload raw-len bit-len)]
    [main-start : i64 (tlci-codec-test-main-start)]
    [distance-start : i64 (tlci-codec-test-distance-start)]
    [length-start : i64 (tlci-codec-test-length-start)]
    [bit-start : i64 (+ length-start 16)]
    [bit-bytes : i64
      (+
        (/ bit-len 8)
        (if (= (% bit-len 8) 0)
          0
          1))]
    (begin
      ;; A, B, C, match are the four two-bit canonical main symbols.
      (set! (array-ref payload (+ main-start 65)) (cast 2 : u8))
      (set! (array-ref payload (+ main-start 66)) (cast 2 : u8))
      (set! (array-ref payload (+ main-start 67)) (cast 2 : u8))
      (set! (array-ref payload (+ main-start 256)) (cast 2 : u8))
      ;; Distance symbols 0/2 and length symbols 0/1 form complete one-bit trees.
      (set! (array-ref payload distance-start) (cast 1 : u8))
      (set! (array-ref payload (+ distance-start 2)) (cast 1 : u8))
      (set! (array-ref payload length-start) (cast 1 : u8))
      (set! (array-ref payload (+ length-start 1)) (cast 1 : u8))
      (if (> bit-bytes 0)
        (set! (array-ref payload bit-start) (cast first : u8))
        unit)
      (if (> bit-bytes 1)
        (set! (array-ref payload (+ bit-start 1)) (cast second : u8))
        unit)
      payload)))

(define (tlci-codec-test-literal-payload
  [raw-len : i64]
  [bit-len : i64]
  [first : i64]) : (__tl_dyn-array u8)
  (let
    [payload : (__tl_dyn-array u8)
      (tlci-codec-test-base-payload raw-len bit-len)]
    [main-start : i64 (tlci-codec-test-main-start)]
    [bit-start : i64 (+ (tlci-codec-test-length-start) 16)]
    (begin
      (set! (array-ref payload (+ main-start 65)) (cast 1 : u8))
      (set! (array-ref payload (+ main-start 66)) (cast 1 : u8))
      (if (> bit-len 0)
        (set! (array-ref payload bit-start) (cast first : u8))
        unit)
      payload)))

(define (tlci-codec-test-append-zero [payload : (__tl_dyn-array u8)]) : (__tl_dyn-array
    u8)
  (let
    [length : i64 (array-length payload)]
    [out : (__tl_dyn-array u8) (array.make-array u8 (+ length 1))]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (set! (array-ref out index) (array-ref payload index))
          (set! index (+ index 1))))
      out)))

(define (tlci-codec-test-take [payload : (__tl_dyn-array u8)] [length : i64]) : (__tl_dyn-array
    u8)
  (let
    [out : (__tl_dyn-array u8) (array.make-array u8 length)]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (set! (array-ref out index) (array-ref payload index))
          (set! index (+ index 1))))
      out)))

(define (tlci-codec-test-rejects?
  [payload : (__tl_dyn-array u8)]
  [raw-limit : i64]
  [expected : String]) : bool
  (match (codec.compiler-embedded-stdlib-tlci-codec-decode
    (& payload)
    raw-limit)
    [(codec.CompilerEmbeddedStdlibTlciCodecBytes.Err message)
      (string.eq message expected)]
    [(codec.CompilerEmbeddedStdlibTlciCodecBytes.Ok _) false]))

(define (tlci-codec-self-test-status) : i64
  (cond
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-match-payload 6 10 27 128)]
          (match (codec.compiler-embedded-stdlib-tlci-codec-decode
            (& payload)
            64)
            [(codec.CompilerEmbeddedStdlibTlciCodecBytes.Ok bytes)
              (and
                (= (array-length bytes) 6)
                (= (array-ref bytes 0) (cast 65 : u8))
                (= (array-ref bytes 3) (cast 65 : u8))
                (= (array-ref bytes 5) (cast 67 : u8)))]
            [(codec.CompilerEmbeddedStdlibTlciCodecBytes.Err _) false])))
      1]
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-literal-payload 1 1 0)]
          (match (codec.compiler-embedded-stdlib-tlci-codec-decode
            (& payload)
            64)
            [(codec.CompilerEmbeddedStdlibTlciCodecBytes.Ok bytes)
              (and
                (= (array-length bytes) 1)
                (= (array-ref bytes 0) (cast 65 : u8)))]
            [(codec.CompilerEmbeddedStdlibTlciCodecBytes.Err _) false])))
      2]
    [(not
        (tlci-codec-test-rejects?
          (__tl_make-array 0)
          64
          "embedded stdlib tlci envelope: bad prefix or version"))
      3]
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-match-payload 6 10 27 128)]
          (begin
            (set! (array-ref payload 0) (cast 0 : u8))
            (tlci-codec-test-rejects?
              payload
              64
              "embedded stdlib tlci envelope: bad prefix or version"))))
      4]
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-match-payload 6 10 27 128)]
          (begin
            (set!
              (array-ref
                payload
                (+
                  (string.string-length
                    (codec.compiler-embedded-stdlib-tlci-codec-prefix))
                  7))
              (cast 128 : u8))
            (tlci-codec-test-rejects?
              payload
              64
              "embedded stdlib tlci envelope: raw length overflows i64"))))
      5]
    [(not
        (tlci-codec-test-rejects?
          (tlci-codec-test-match-payload 6 10 27 128)
          5
          "embedded stdlib tlci envelope: raw length exceeds consumer limit"))
      6]
    [(not
        (tlci-codec-test-rejects?
          (tlci-codec-test-append-zero
            (tlci-codec-test-match-payload 6 10 27 128))
          64
          "embedded stdlib tlci envelope: trailing compressed bytes"))
      7]
    [(not
        (tlci-codec-test-rejects?
          (tlci-codec-test-match-payload 6 10 27 129)
          64
          "embedded stdlib tlci envelope: nonzero padding bits"))
      8]
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-literal-payload 1 1 0)]
          (begin
            (set!
              (array-ref payload (+ (tlci-codec-test-main-start) 65))
              (cast 32 : u8))
            (tlci-codec-test-rejects?
              payload
              64
              "embedded stdlib tlci envelope: invalid huffman code length"))))
      9]
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-literal-payload 1 1 0)]
          (begin
            (set!
              (array-ref payload (+ (tlci-codec-test-main-start) 67))
              (cast 1 : u8))
            (tlci-codec-test-rejects?
              payload
              64
              "embedded stdlib tlci envelope: oversubscribed huffman table"))))
      10]
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-literal-payload 1 1 0)]
          (begin
            (set!
              (array-ref payload (+ (tlci-codec-test-main-start) 65))
              (cast 2 : u8))
            (set!
              (array-ref payload (+ (tlci-codec-test-main-start) 66))
              (cast 2 : u8))
            (tlci-codec-test-rejects?
              payload
              64
              "embedded stdlib tlci envelope: incomplete huffman table"))))
      11]
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-match-payload 6 10 27 128)]
          (begin
            (set!
              (array-ref payload (tlci-codec-test-distance-start))
              (cast 0 : u8))
            (set!
              (array-ref payload (+ (tlci-codec-test-distance-start) 2))
              (cast 0 : u8))
            (tlci-codec-test-rejects?
              payload
              64
              "embedded stdlib tlci envelope: missing match huffman table"))))
      12]
    [(not
        (tlci-codec-test-rejects?
          (tlci-codec-test-match-payload 6 1 0 0)
          64
          "embedded stdlib tlci envelope: truncated huffman code"))
      13]
    [(not
        (tlci-codec-test-rejects?
          (tlci-codec-test-match-payload 3 4 224 0)
          64
          "embedded stdlib tlci envelope: backreference before output"))
      14]
    [(not
        (tlci-codec-test-rejects?
          (tlci-codec-test-match-payload 2 6 48 0)
          64
          "embedded stdlib tlci envelope: backreference exceeds output"))
      15]
    [(not
        (tlci-codec-test-rejects?
          (tlci-codec-test-literal-payload 1 2 0)
          64
          "embedded stdlib tlci envelope: trailing huffman bits"))
      16]
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-match-payload 6 10 27 128)]
          (begin
            (set!
              (array-ref
                payload
                (+
                  (string.string-length
                    (codec.compiler-embedded-stdlib-tlci-codec-prefix))
                  15))
              (cast 128 : u8))
            (tlci-codec-test-rejects?
              payload
              64
              "embedded stdlib tlci envelope: bit length overflows i64"))))
      17]
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-match-payload 6 10 27 128)]
          (tlci-codec-test-rejects?
            (tlci-codec-test-take
              payload
              (+
                (string.string-length
                  (codec.compiler-embedded-stdlib-tlci-codec-prefix))
                8))
            64
            "embedded stdlib tlci envelope: truncated header")))
      18]
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-match-payload 6 10 27 128)]
          (tlci-codec-test-rejects?
            (tlci-codec-test-take payload (- (array-length payload) 1))
            64
            "embedded stdlib tlci envelope: truncated bitstream")))
      19]
    [(not
        (let
          [payload : (__tl_dyn-array u8)
            (tlci-codec-test-literal-payload 1 1 0)]
          (begin
            (set!
              (array-ref payload (tlci-codec-test-distance-start))
              (cast 1 : u8))
            (set!
              (array-ref payload (+ (tlci-codec-test-distance-start) 1))
              (cast 1 : u8))
            (set!
              (array-ref payload (tlci-codec-test-length-start))
              (cast 1 : u8))
            (set!
              (array-ref payload (+ (tlci-codec-test-length-start) 1))
              (cast 1 : u8))
            (tlci-codec-test-rejects?
              payload
              64
              "embedded stdlib tlci envelope: unexpected match huffman table"))))
      20]
    [(not
        (tlci-codec-test-rejects?
          (tlci-codec-test-match-payload 6 10 27 128)
          -1
          "embedded stdlib tlci envelope: invalid raw length limit"))
      21]
    [(not
        (tlci-codec-test-rejects?
          (tlci-codec-test-literal-payload 0 0 0)
          64
          "embedded stdlib tlci envelope: nonempty tables for empty output"))
      22]
    [else 0]))

(test
  compiler-embedded-stdlib-tlci-bounded-envelope
  (if (= (tlci-codec-self-test-status) 0)
    unit
    (string.tl_oob_abort)))