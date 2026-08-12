;; Bounded decoder for the compiler-owned embedded stdlib TLCI envelope.
;;
;; The ordinary `.tlci` image remains unchanged. Its existing LZSS token stream
;; is represented here by three canonical Huffman alphabets: literal-or-match,
;; match distance, and match length. Code lengths are stored explicitly so the
;; decoder owns no fixed model and repeated encoder runs are byte-identical.
(import stdlib.array)
(import stdlib.string)

(define (compiler-embedded-stdlib-tlci-codec-main-symbols) : i64
  257)

(define (compiler-embedded-stdlib-tlci-codec-distance-symbols) : i64
  4096)

(define (compiler-embedded-stdlib-tlci-codec-length-symbols) : i64
  16)

(define (compiler-embedded-stdlib-tlci-codec-max-code-bits) : i64
  31)

(define (compiler-embedded-stdlib-tlci-codec-lookup-bits) : i64
  12)

(define (compiler-embedded-stdlib-tlci-codec-lookup-size) : i64
  4096)

(define (compiler-embedded-stdlib-tlci-codec-prefix) : String
  "__typelisp_embedded_stdlib_tlch_v1__")

(defenum CompilerEmbeddedStdlibTlciCodecFrame
  (Err String)
  ;; uncompressed byte length, meaningful bit count, first bitstream byte
  (Ok i64 i64 i64))

(defenum CompilerEmbeddedStdlibTlciCodecBytes
  (Err String)
  (Ok (__tl_dyn-array u8)))

(defstruct CompilerEmbeddedStdlibTlciHuffmanTable
  (counts (__tl_dyn-array i64))
  (first-codes (__tl_dyn-array i64))
  (first-symbols (__tl_dyn-array i64))
  (symbols (__tl_dyn-array i64))
  ;; Packed direct entries: code length in the high bits, symbol+1 in the low.
  (lookup (__tl_dyn-array i64))
  (active i64)
  (max-bits i64))

(defenum ResultCompilerEmbeddedStdlibTlciHuffmanTable
  (Err String)
  (Ok CompilerEmbeddedStdlibTlciHuffmanTable))

(defenum ResultCompilerEmbeddedStdlibTlciHuffmanSymbol
  (Err String)
  (Ok i64))

(define (compiler-embedded-stdlib-tlci-codec-prefix?
  [payload : (& payload (__tl_dyn-array u8))]
  [prefix : String]) : bool
  (let
    [index : i64 0]
    [prefix-len : i64 (string.string-length prefix)]
    [matches : bool (>= (array-length payload) prefix-len)]
    (begin
      (while (and matches (< index prefix-len))
        (begin
          (if (!=
            (array-ref payload index)
            (cast (string.string-ref prefix index) : u8))
            (set! matches false)
            unit)
          (set! index (+ index 1))))
      matches)))

;; Caller proves eight bytes are present and byte seven has its high bit clear.
(define (compiler-embedded-stdlib-tlci-codec-read-i64-le
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]) : i64
  (let
    [index : i64 0]
    [value : i64 0]
    (begin
      (while (< index 8)
        (begin
          (set!
            value
            (bit-or
              value
              (shl (cast (array-ref payload (+ start index)) : i64) (* index 8))))
          (set! index (+ index 1))))
      value)))

(define (compiler-embedded-stdlib-tlci-codec-table-bytes) : i64
  (+
    (compiler-embedded-stdlib-tlci-codec-main-symbols)
    (+
      (compiler-embedded-stdlib-tlci-codec-distance-symbols)
      (compiler-embedded-stdlib-tlci-codec-length-symbols))))

;: Validate the fixed envelope and return its bounded allocation/bit metadata.
(define (compiler-embedded-stdlib-tlci-codec-frame
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : CompilerEmbeddedStdlibTlciCodecFrame
  (let
    [prefix : String (compiler-embedded-stdlib-tlci-codec-prefix)]
    [prefix-len : i64 (string.string-length prefix)]
    [header-len : i64
      (+ prefix-len (+ 16 (compiler-embedded-stdlib-tlci-codec-table-bytes)))]
    [payload-len : i64 (array-length payload)]
    (cond
      [(< raw-limit 0)
        (CompilerEmbeddedStdlibTlciCodecFrame.Err
          "embedded stdlib tlci envelope: invalid raw length limit")]
      [(not (compiler-embedded-stdlib-tlci-codec-prefix? payload prefix))
        (CompilerEmbeddedStdlibTlciCodecFrame.Err
          "embedded stdlib tlci envelope: bad prefix or version")]
      [(< payload-len header-len)
        (CompilerEmbeddedStdlibTlciCodecFrame.Err
          "embedded stdlib tlci envelope: truncated header")]
      [(>= (array-ref payload (+ prefix-len 7)) (cast 128 : u8))
        (CompilerEmbeddedStdlibTlciCodecFrame.Err
          "embedded stdlib tlci envelope: raw length overflows i64")]
      [(>= (array-ref payload (+ prefix-len 15)) (cast 128 : u8))
        (CompilerEmbeddedStdlibTlciCodecFrame.Err
          "embedded stdlib tlci envelope: bit length overflows i64")]
      [else
        (let
          [raw-len : i64
            (compiler-embedded-stdlib-tlci-codec-read-i64-le payload prefix-len)]
          [bit-len : i64
            (compiler-embedded-stdlib-tlci-codec-read-i64-le
              payload
              (+ prefix-len 8))]
          [bit-bytes : i64
            (+
              (/ bit-len 8)
              (if (= (% bit-len 8) 0)
                0
                1))]
          [available : i64 (- payload-len header-len)]
          (cond
            [(> raw-len raw-limit)
              (CompilerEmbeddedStdlibTlciCodecFrame.Err
                "embedded stdlib tlci envelope: raw length exceeds consumer limit")]
            [(> bit-bytes available)
              (CompilerEmbeddedStdlibTlciCodecFrame.Err
                "embedded stdlib tlci envelope: truncated bitstream")]
            [(< bit-bytes available)
              (CompilerEmbeddedStdlibTlciCodecFrame.Err
                "embedded stdlib tlci envelope: trailing compressed bytes")]
            [(and
                (> bit-bytes 0)
                (!= (% bit-len 8) 0)
                (!=
                  (bit-and
                    (cast (array-ref payload (- payload-len 1)) : i64)
                    (- (shl 1 (- 8 (% bit-len 8))) 1))
                  0))
              (CompilerEmbeddedStdlibTlciCodecFrame.Err
                "embedded stdlib tlci envelope: nonzero padding bits")]
            [else
              (CompilerEmbeddedStdlibTlciCodecFrame.Ok
                raw-len
                bit-len
                header-len)]))])))

(define (compiler-embedded-stdlib-tlci-codec-build-table
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]
  [alphabet-size : i64]) : ResultCompilerEmbeddedStdlibTlciHuffmanTable
  (let
    [slot-count : i64 (+ (compiler-embedded-stdlib-tlci-codec-max-code-bits) 1)]
    [counts : (__tl_dyn-array i64) (array.make-array i64 slot-count)]
    [first-codes : (__tl_dyn-array i64) (array.make-array i64 slot-count)]
    [first-symbols : (__tl_dyn-array i64) (array.make-array i64 slot-count)]
    [active : i64 0]
    [max-bits : i64 0]
    [symbol : i64 0]
    (begin
      (while (< symbol alphabet-size)
        (let
          [bits : i64 (cast (array-ref payload (+ start symbol)) : i64)]
          (begin
            (if (> bits (compiler-embedded-stdlib-tlci-codec-max-code-bits))
              (return
                (ResultCompilerEmbeddedStdlibTlciHuffmanTable.Err
                  "embedded stdlib tlci envelope: invalid huffman code length"))
              unit)
            (if (> bits 0)
              (begin
                (set! (array-ref counts bits) (+ (array-ref counts bits) 1))
                (set! active (+ active 1))
                (if (> bits max-bits)
                  (set! max-bits bits)
                  unit))
              unit)
            (set! symbol (+ symbol 1)))))
      (if (= active 0)
        (ResultCompilerEmbeddedStdlibTlciHuffmanTable.Ok
          (CompilerEmbeddedStdlibTlciHuffmanTable
            counts
            first-codes
            first-symbols
            (array.make-array i64 0)
            (array.make-array
              i64
              (compiler-embedded-stdlib-tlci-codec-lookup-size))
            0
            0))
        (let
          [bits : i64 1]
          [left : i64 1]
          (begin
            (while (<= bits max-bits)
              (begin
                (set! left (- (* left 2) (array-ref counts bits)))
                (if (< left 0)
                  (return
                    (ResultCompilerEmbeddedStdlibTlciHuffmanTable.Err
                      "embedded stdlib tlci envelope: oversubscribed huffman table"))
                  unit)
                (set! bits (+ bits 1))))
            (if (!= left 0)
              (ResultCompilerEmbeddedStdlibTlciHuffmanTable.Err
                "embedded stdlib tlci envelope: incomplete huffman table")
              (let
                [code : i64 0]
                [ordered : i64 0]
                [code-bits : i64 1]
                [symbols : (__tl_dyn-array i64) (array.make-array i64 active)]
                [next : (__tl_dyn-array i64) (array.make-array i64 slot-count)]
                [lookup : (__tl_dyn-array i64)
                  (array.make-array
                    i64
                    (compiler-embedded-stdlib-tlci-codec-lookup-size))]
                (begin
                  (while (<= code-bits max-bits)
                    (begin
                      (set!
                        code
                        (shl (+ code (array-ref counts (- code-bits 1))) 1))
                      (set! (array-ref first-codes code-bits) code)
                      (set! (array-ref first-symbols code-bits) ordered)
                      (set! (array-ref next code-bits) ordered)
                      (set! ordered (+ ordered (array-ref counts code-bits)))
                      (set! code-bits (+ code-bits 1))))
                  (set! symbol 0)
                  (while (< symbol alphabet-size)
                    (let
                      [length : i64
                        (cast (array-ref payload (+ start symbol)) : i64)]
                      (begin
                        (if (> length 0)
                          (let
                            [position : i64 (array-ref next length)]
                            (begin
                              (set! (array-ref symbols position) symbol)
                              (set! (array-ref next length) (+ position 1))))
                          unit)
                        (set! symbol (+ symbol 1)))))
                  ;; Directly expand all codes up to 12 bits. Main and length
                  ;; symbols always fit; over 90% of real distance tokens do as
                  ;; well. Longer rare distances retain the canonical fallback.
                  (set! code-bits 1)
                  (while (and
                    (<= code-bits max-bits)
                    (<=
                      code-bits
                      (compiler-embedded-stdlib-tlci-codec-lookup-bits)))
                    (let
                      [offset : i64 0]
                      [count : i64 (array-ref counts code-bits)]
                      [repeats : i64
                        (shl
                          1
                          (-
                            (compiler-embedded-stdlib-tlci-codec-lookup-bits)
                            code-bits))]
                      (begin
                        (while (< offset count)
                          (let
                            [canonical : i64
                              (+ (array-ref first-codes code-bits) offset)]
                            [decoded : i64
                              (array-ref
                                symbols
                                (+ (array-ref first-symbols code-bits) offset))]
                            [base : i64 (* canonical repeats)]
                            [repeat : i64 0]
                            [packed : i64
                              (bit-or (shl code-bits 13) (+ decoded 1))]
                            (begin
                              (while (< repeat repeats)
                                (begin
                                  (set!
                                    (array-ref lookup (+ base repeat))
                                    packed)
                                  (set! repeat (+ repeat 1))))
                              (set! offset (+ offset 1)))))
                        (set! code-bits (+ code-bits 1)))))
                  (ResultCompilerEmbeddedStdlibTlciHuffmanTable.Ok
                    (CompilerEmbeddedStdlibTlciHuffmanTable
                      counts
                      first-codes
                      first-symbols
                      symbols
                      lookup
                      active
                      max-bits)))))))))))

(define (compiler-embedded-stdlib-tlci-codec-decode-symbol
  [payload : (& payload (__tl_dyn-array u8))]
  [bit-start : i64]
  [bit-len : i64]
  [bit-index : (&mut bit-index i64)]
  [table : (& table CompilerEmbeddedStdlibTlciHuffmanTable)]) : ResultCompilerEmbeddedStdlibTlciHuffmanSymbol
  (if (= table.active 0)
    (ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Err
      "embedded stdlib tlci envelope: missing huffman table")
    (begin
      (if (>=
        (- bit-len (deref bit-index))
        (compiler-embedded-stdlib-tlci-codec-lookup-bits))
        (let
          [absolute : i64 (deref bit-index)]
          [byte-index : i64 (+ bit-start (/ absolute 8))]
          [offset : i64 (% absolute 8)]
          [first : i64 (cast (array-ref payload byte-index) : i64)]
          [second : i64 (cast (array-ref payload (+ byte-index 1)) : i64)]
          [third : i64
            (if (> offset 4)
              (cast (array-ref payload (+ byte-index 2)) : i64)
              0)]
          [window : i64 (bit-or (shl first 16) (bit-or (shl second 8) third))]
          [prefix : i64 (bit-and (shr window (- 12 offset)) 4095)]
          [entry : i64 (array-ref table.lookup prefix)]
          (if (> entry 0)
            (let
              [length : i64 (shr entry 13)]
              [symbol : i64 (- (bit-and entry 8191) 1)]
              (begin
                (set! (deref bit-index) (+ absolute length))
                (return
                  (ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Ok symbol))))
            unit))
        unit)
      (let
        [code : i64 0]
        [bits : i64 1]
        (begin
          (while (<= bits table.max-bits)
            (begin
              (if (>= (deref bit-index) bit-len)
                (return
                  (ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Err
                    "embedded stdlib tlci envelope: truncated huffman code"))
                unit)
              (let
                [absolute : i64 (deref bit-index)]
                [byte : i64
                  (cast (array-ref payload (+ bit-start (/ absolute 8))) : i64)]
                [bit : i64 (bit-and (shr byte (- 7 (% absolute 8))) 1)]
                (begin
                  (set! (deref bit-index) (+ absolute 1))
                  (set! code (bit-or (shl code 1) bit))))
              (let
                [first : i64 (array-ref table.first-codes bits)]
                [count : i64 (array-ref table.counts bits)]
                [offset : i64 (- code first)]
                (if (and (>= offset 0) (< offset count))
                  (return
                    (ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Ok
                      (array-ref
                        table.symbols
                        (+ (array-ref table.first-symbols bits) offset))))
                  unit))
              (set! bits (+ bits 1))))
          (ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Err
            "embedded stdlib tlci envelope: invalid huffman code"))))))

(define (compiler-embedded-stdlib-tlci-codec-decode-with-tables
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-len : i64]
  [bit-len : i64]
  [bit-start : i64]
  [main-start : i64]
  [main-table : CompilerEmbeddedStdlibTlciHuffmanTable]
  [distance-table : CompilerEmbeddedStdlibTlciHuffmanTable]
  [length-table : CompilerEmbeddedStdlibTlciHuffmanTable]) : CompilerEmbeddedStdlibTlciCodecBytes
  (let
    [match-present : bool
      (> (array-ref payload (+ main-start 256)) (cast 0 : u8))]
    (cond
      [(and (= raw-len 0) (!= bit-len 0))
        (CompilerEmbeddedStdlibTlciCodecBytes.Err
          "embedded stdlib tlci envelope: nonempty stream for empty output")]
      [(and
          (= raw-len 0)
          (or
            (> main-table.active 0)
            (> distance-table.active 0)
            (> length-table.active 0)))
        (CompilerEmbeddedStdlibTlciCodecBytes.Err
          "embedded stdlib tlci envelope: nonempty tables for empty output")]
      [(and (> raw-len 0) (= main-table.active 0))
        (CompilerEmbeddedStdlibTlciCodecBytes.Err
          "embedded stdlib tlci envelope: missing main huffman table")]
      [(and
          match-present
          (or (= distance-table.active 0) (= length-table.active 0)))
        (CompilerEmbeddedStdlibTlciCodecBytes.Err
          "embedded stdlib tlci envelope: missing match huffman table")]
      [(and
          (not match-present)
          (or (> distance-table.active 0) (> length-table.active 0)))
        (CompilerEmbeddedStdlibTlciCodecBytes.Err
          "embedded stdlib tlci envelope: unexpected match huffman table")]
      [else
        (let
          [out : (__tl_dyn-array u8) (array.make-array u8 raw-len)]
          [out-index : i64 0]
          [bit-index : i64 0]
          (begin
            (while (< out-index raw-len)
              (match (compiler-embedded-stdlib-tlci-codec-decode-symbol
                payload
                bit-start
                bit-len
                (&mut bit-index)
                (& main-table))
                [(ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Err message)
                  (return (CompilerEmbeddedStdlibTlciCodecBytes.Err message))]
                [(ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Ok symbol)
                  (if (< symbol 256)
                    (begin
                      (set! (array-ref out out-index) (cast symbol : u8))
                      (set! out-index (+ out-index 1)))
                    (let
                      [distance-symbol : i64
                        (match (compiler-embedded-stdlib-tlci-codec-decode-symbol
                          payload
                          bit-start
                          bit-len
                          (&mut bit-index)
                          (& distance-table))
                          [(ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Err
                              message)
                            (return
                              (CompilerEmbeddedStdlibTlciCodecBytes.Err message))]
                          [(ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Ok
                              value)
                            value])]
                      [length-symbol : i64
                        (match (compiler-embedded-stdlib-tlci-codec-decode-symbol
                          payload
                          bit-start
                          bit-len
                          (&mut bit-index)
                          (& length-table))
                          [(ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Err
                              message)
                            (return
                              (CompilerEmbeddedStdlibTlciCodecBytes.Err message))]
                          [(ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Ok
                              value)
                            value])]
                      [distance : i64 (+ distance-symbol 1)]
                      [length : i64 (+ length-symbol 3)]
                      (cond
                        [(> distance out-index)
                          (return
                            (CompilerEmbeddedStdlibTlciCodecBytes.Err
                              "embedded stdlib tlci envelope: backreference before output"))]
                        [(> length (- raw-len out-index))
                          (return
                            (CompilerEmbeddedStdlibTlciCodecBytes.Err
                              "embedded stdlib tlci envelope: backreference exceeds output"))]
                        [else
                          (let
                            [copied : i64 0]
                            (while (< copied length)
                              (begin
                                (set!
                                  (array-ref out out-index)
                                  (array-ref out (- out-index distance)))
                                (set! out-index (+ out-index 1))
                                (set! copied (+ copied 1)))))])))]))
            (if (!= bit-index bit-len)
              (CompilerEmbeddedStdlibTlciCodecBytes.Err
                "embedded stdlib tlci envelope: trailing huffman bits")
              (CompilerEmbeddedStdlibTlciCodecBytes.Ok out))))])))

;: Decode one complete embedded-image envelope after fail-closed validation.
(define (compiler-embedded-stdlib-tlci-codec-decode
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : CompilerEmbeddedStdlibTlciCodecBytes
  (match (compiler-embedded-stdlib-tlci-codec-frame payload raw-limit)
    [(CompilerEmbeddedStdlibTlciCodecFrame.Err message)
      (CompilerEmbeddedStdlibTlciCodecBytes.Err message)]
    [(CompilerEmbeddedStdlibTlciCodecFrame.Ok raw-len bit-len bit-start)
      (let
        [prefix-len : i64
          (string.string-length (compiler-embedded-stdlib-tlci-codec-prefix))]
        [main-start : i64 (+ prefix-len 16)]
        [distance-start : i64
          (+ main-start (compiler-embedded-stdlib-tlci-codec-main-symbols))]
        [length-start : i64
          (+
            distance-start
            (compiler-embedded-stdlib-tlci-codec-distance-symbols))]
        (match (compiler-embedded-stdlib-tlci-codec-build-table
          payload
          main-start
          (compiler-embedded-stdlib-tlci-codec-main-symbols))
          [(ResultCompilerEmbeddedStdlibTlciHuffmanTable.Err message)
            (CompilerEmbeddedStdlibTlciCodecBytes.Err message)]
          [(ResultCompilerEmbeddedStdlibTlciHuffmanTable.Ok main-table)
            (match (compiler-embedded-stdlib-tlci-codec-build-table
              payload
              distance-start
              (compiler-embedded-stdlib-tlci-codec-distance-symbols))
              [(ResultCompilerEmbeddedStdlibTlciHuffmanTable.Err message)
                (CompilerEmbeddedStdlibTlciCodecBytes.Err message)]
              [(ResultCompilerEmbeddedStdlibTlciHuffmanTable.Ok distance-table)
                (match (compiler-embedded-stdlib-tlci-codec-build-table
                  payload
                  length-start
                  (compiler-embedded-stdlib-tlci-codec-length-symbols))
                  [(ResultCompilerEmbeddedStdlibTlciHuffmanTable.Err message)
                    (CompilerEmbeddedStdlibTlciCodecBytes.Err message)]
                  [(ResultCompilerEmbeddedStdlibTlciHuffmanTable.Ok
                      length-table)
                    (compiler-embedded-stdlib-tlci-codec-decode-with-tables
                      payload
                      raw-len
                      bit-len
                      bit-start
                      main-start
                      main-table
                      distance-table
                      length-table)])])]))]))