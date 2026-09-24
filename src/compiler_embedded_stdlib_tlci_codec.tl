;; Bounded decoder for the compiler-owned embedded stdlib TLCI envelope.
;;
;; The ordinary `.tlci` image remains unchanged. Its existing LZSS token stream
;; is represented here by three canonical Huffman alphabets: literal-or-match,
;; match distance, and match length. Code lengths are stored explicitly so the
;; decoder owns no fixed model and repeated encoder runs are byte-identical.
(import stdlib.string)
(import compiler_owned_view as owned_view)

(define (compiler-embedded-stdlib-tlci-codec-main-symbols) : i64
  257)

(define (compiler-embedded-stdlib-tlci-codec-distance-symbols) : i64
  4096)

(define (compiler-embedded-stdlib-tlci-codec-length-symbols) : i64
  16)

(define (compiler-embedded-stdlib-tlci-codec-max-code-bits) : i64
  31)

(define (compiler-embedded-stdlib-tlci-codec-lookup-bits) : i64
  16)

(define (compiler-embedded-stdlib-tlci-codec-lookup-size) : i64
  65536)

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

(defstruct CompilerEmbeddedStdlibTlciBitReader
  (next-byte i64)
  ;; Only the low `available` bits are live; consumed high bits are ignored.
  (buffer i64)
  (available i64)
  (consumed i64))

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
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 slot-count)]
    [first-codes : (__tl_dyn-array i64) (__tl_make-array i64 slot-count)]
    [first-symbols : (__tl_dyn-array i64) (__tl_make-array i64 slot-count)]
    [active : i64 0]
    [max-bits : i64 0]
    [symbol : i64 0]
    (begin
      (while (< symbol alphabet-size)
        (let
          [bits : i64 (cast (array-ref payload (+ start symbol)) : i64)]
          (begin
            (when
              (> bits (compiler-embedded-stdlib-tlci-codec-max-code-bits))
              (return
                (ResultCompilerEmbeddedStdlibTlciHuffmanTable.Err
                  "embedded stdlib tlci envelope: invalid huffman code length")))
            (when
              (> bits 0)
              (set! (array-ref counts bits) (+ (array-ref counts bits) 1))
              (set! active (+ active 1))
              (when (> bits max-bits) (set! max-bits bits)))
            (set! symbol (+ symbol 1)))))
      (if (= active 0)
        (ResultCompilerEmbeddedStdlibTlciHuffmanTable.Ok
          (CompilerEmbeddedStdlibTlciHuffmanTable
            counts
            first-codes
            first-symbols
            (__tl_make-array i64 0)
            (__tl_make-array
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
                (when
                  (< left 0)
                  (return
                    (ResultCompilerEmbeddedStdlibTlciHuffmanTable.Err
                      "embedded stdlib tlci envelope: oversubscribed huffman table")))
                (set! bits (+ bits 1))))
            (if (!= left 0)
              (ResultCompilerEmbeddedStdlibTlciHuffmanTable.Err
                "embedded stdlib tlci envelope: incomplete huffman table")
              (let
                [code : i64 0]
                [ordered : i64 0]
                [code-bits : i64 1]
                [symbols : (__tl_dyn-array i64) (__tl_make-array i64 active)]
                [next : (__tl_dyn-array i64) (__tl_make-array i64 slot-count)]
                [lookup : (__tl_dyn-array i64)
                  (__tl_make-array
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
                  ;; Directly expand all codes up to 16 bits. Main and length
                  ;; symbols always fit and effectively all real distance tokens
                  ;; do too. Longer malformed/rare tables retain the fallback.
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
  [bit-len : i64]
  [reader : (&mut reader CompilerEmbeddedStdlibTlciBitReader)]
  [table : (& table CompilerEmbeddedStdlibTlciHuffmanTable)]) : ResultCompilerEmbeddedStdlibTlciHuffmanSymbol
  (if (= table.active 0)
    (ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Err
      "embedded stdlib tlci envelope: missing huffman table")
    (begin
      (if (>=
        (- bit-len reader.consumed)
        (compiler-embedded-stdlib-tlci-codec-lookup-bits))
        (begin
          (while (<
            reader.available
            (compiler-embedded-stdlib-tlci-codec-lookup-bits))
            (begin
              (set!
                reader.buffer
                (bit-or
                  (shl reader.buffer 8)
                  (cast (array-ref payload reader.next-byte) : i64)))
              (set! reader.next-byte (+ reader.next-byte 1))
              (set! reader.available (+ reader.available 8))))
          (let
            [prefix : i64
              (bit-and
                (shr
                  reader.buffer
                  (-
                    reader.available
                    (compiler-embedded-stdlib-tlci-codec-lookup-bits)))
                65535)]
            [entry : i64 (array-ref table.lookup prefix)]
            (when
              (> entry 0)
              (let
                [length : i64 (shr entry 13)]
                [symbol : i64 (- (bit-and entry 8191) 1)]
                [remaining : i64 (- reader.available length)]
                (begin
                  (set! reader.available remaining)
                  (set! reader.consumed (+ reader.consumed length))
                  (return
                    (ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Ok symbol)))))))
        unit)
      (let
        [code : i64 0]
        [bits : i64 1]
        (begin
          (while (<= bits table.max-bits)
            (begin
              (when
                (>= reader.consumed bit-len)
                (return
                  (ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Err
                    "embedded stdlib tlci envelope: truncated huffman code")))
              (let
                [bit : i64 0]
                (begin
                  (when
                    (= reader.available 0)
                    (set!
                      reader.buffer
                      (cast (array-ref payload reader.next-byte) : i64))
                    (set! reader.next-byte (+ reader.next-byte 1))
                    (set! reader.available 8))
                  (set!
                    bit
                    (bit-and (shr reader.buffer (- reader.available 1)) 1))
                  (set! reader.available (- reader.available 1))
                  (set! reader.consumed (+ reader.consumed 1))
                  (set! code (bit-or (shl code 1) bit))))
              (let
                [first : i64 (array-ref table.first-codes bits)]
                [count : i64 (array-ref table.counts bits)]
                [offset : i64 (- code first)]
                (when
                  (and (>= offset 0) (< offset count))
                  (return
                    (ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Ok
                      (array-ref
                        table.symbols
                        (+ (array-ref table.first-symbols bits) offset))))))
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
        ;; The bit reader lives in locals and a symbol whose 16-bit prefix hits
        ;; its table's direct entry is decoded right here, exactly as the first
        ;; branch of decode-symbol would; every other symbol -- a longer code,
        ;; or one within 16 bits of the stream's end -- goes through
        ;; decode-symbol itself on a reader rebuilt from the locals. Once per
        ;; symbol of a 16 MB image, the call, its Result and a reader behind a
        ;; reference were most of a small program's compile.
        (let
          [out : (__tl_dyn-array u8) (__tl_make-array u8 raw-len)]
          [out-index : i64 0]
          [main-lookup : (__tl_dyn-array i64) main-table.lookup]
          [distance-lookup : (__tl_dyn-array i64) distance-table.lookup]
          [length-lookup : (__tl_dyn-array i64) length-table.lookup]
          [fast-limit : i64
            (- bit-len (compiler-embedded-stdlib-tlci-codec-lookup-bits))]
          [next-byte : i64 bit-start]
          [buffer : i64 0]
          [available : i64 0]
          [consumed : i64 0]
          [stage : i64 0]
          [symbol : i64 0]
          [distance-symbol : i64 0]
          (begin
            ;; Fast phase, while at least 16 bitstream bytes are unread. One
            ;; refill to 48+ bits then covers a whole token -- a literal, or a
            ;; match's three codes of at most 16 bits each -- and every direct
            ;; read is in range: each table holds exactly lookup-size entries
            ;; and its index is 16 bits. A token that needs anything else (a
            ;; longer code, or a match the general loop would reject) leaves
            ;; this loop before consuming a bit, and the general loop below
            ;; decodes it, errors included, exactly as it always has.
            (let
              [lookup-size : i64
                (compiler-embedded-stdlib-tlci-codec-lookup-size)]
              [byte-limit : i64 (- (array-length payload) 16)]
              [tables-ok? : bool
                (and
                  (= (array-length main-lookup) lookup-size)
                  (= (array-length distance-lookup) lookup-size)
                  (= (array-length length-lookup) lookup-size))]
              [fast? : bool false]
              [out-data : (MutPtr u8)
                (unsafe
                  (__tl_array-data out))]
              ;; The three tables side by side in one array -- main, then
              ;; distance at `lookup-size`, then length at twice that -- so
              ;; the loop keeps one base live instead of three; it is register
              ;; bound, and the other two bases were reloaded from the stack on
              ;; every lookup.
              [tables : (__tl_dyn-array i64)
                (if tables-ok?
                  (let
                    [combined : (__tl_dyn-array i64)
                      (__tl_make-array i64 (* 3 lookup-size))]
                    [k : i64 0]
                    (begin
                      (while (< k lookup-size)
                        (begin
                          (set!
                            (array-ref combined k)
                            (array-ref main-lookup k))
                          (set!
                            (array-ref combined (+ k lookup-size))
                            (array-ref distance-lookup k))
                          (set!
                            (array-ref combined (+ k (* 2 lookup-size)))
                            (array-ref length-lookup k))
                          (set! k (+ k 1))))
                      combined))
                  (__tl_make-array i64 0))]
              [table-data : (MutPtr i64)
                (unsafe
                  (__tl_array-data tables))]
              ;; Refills in this loop read below `next-byte + 8`, inside the
              ;; payload while `next-byte <= byte-limit`.
              [payload-data : (MutPtr u8)
                (unsafe
                  (__tl_array-data
                    (owned_view.compiler-owned-reference-shared-view payload)))]
              (while (< out-index raw-len)
                (begin
                  (set! fast? tables-ok?)
                  (while (and
                    fast?
                    (< out-index raw-len)
                    (<= next-byte byte-limit))
                    (begin
                      (when
                        (< available 48)
                        (while (<= available 56)
                          (begin
                            (set!
                              buffer
                              (bit-or
                                (shl buffer 8)
                                (cast
                                  (unsafe
                                    (ptr-read
                                      (ptr-offset payload-data next-byte)))
                                  : i64)))
                            (set! next-byte (+ next-byte 1))
                            (set! available (+ available 8)))))
                      ;; 48 <= available <= 64 here, so every shift count below
                      ;; is in [0, 48] on the paths that use it.
                      (let
                        [entry : i64
                          (unsafe
                            (ptr-read
                              (ptr-offset
                                table-data
                                (bit-and
                                  (shr buffer (bit-and (- available 16) 63))
                                  65535))))]
                        (cond
                          [(<= entry 0) (set! fast? false)]
                          [(< (bit-and entry 8191) 257)
                            (begin
                              (unsafe
                                (ptr-write!
                                  (ptr-offset out-data out-index)
                                  (cast (- (bit-and entry 8191) 1) : u8)))
                              (set! out-index (+ out-index 1))
                              (set! available (- available (shr entry 13))))]
                          [else
                            (let
                              [after-main : i64 (- available (shr entry 13))]
                              [distance-entry : i64
                                (unsafe
                                  (ptr-read
                                    (ptr-offset
                                      table-data
                                      (+
                                        lookup-size
                                        (bit-and
                                          (shr
                                            buffer
                                            (bit-and (- after-main 16) 63))
                                          65535)))))]
                              (if (<= distance-entry 0)
                                (set! fast? false)
                                (let
                                  [after-distance : i64
                                    (- after-main (shr distance-entry 13))]
                                  [length-entry : i64
                                    (unsafe
                                      (ptr-read
                                        (ptr-offset
                                          table-data
                                          (+
                                            (* 2 lookup-size)
                                            (bit-and
                                              (shr
                                                buffer
                                                (bit-and
                                                  (- after-distance 16)
                                                  63))
                                              65535)))))]
                                  ;; symbol + 1 is the low field: distance is the
                                  ;; distance symbol + 1, length the symbol + 3.
                                  [distance : i64 (bit-and distance-entry 8191)]
                                  [length : i64
                                    (+ (bit-and length-entry 8191) 2)]
                                  (if (or
                                    (<= length-entry 0)
                                    (> distance out-index)
                                    (> length (- raw-len out-index)))
                                    (set! fast? false)
                                    (begin
                                      (set!
                                        available
                                        (- after-distance (shr length-entry 13)))
                                      ;; A source at least a word back is final
                                      ;; for a whole word ahead, so words copy it;
                                      ;; the last may run up to 7 bytes past the
                                      ;; match, inside `out`, and later output
                                      ;; overwrites them before anything reads
                                      ;; them (reads are only ever behind the
                                      ;; write position).
                                      (if (and
                                        (>= distance 8)
                                        (<= (+ out-index (+ length 7)) raw-len))
                                        (let
                                          [dst : (MutPtr u8)
                                            (unsafe
                                              (ptr-offset out-data out-index))]
                                          [copied : i64 0]
                                          (while (< copied length)
                                            (begin
                                              (unsafe
                                                (ptr-write!
                                                  (ptr-cast
                                                    (ptr-offset dst copied)
                                                    : (MutPtr i64))
                                                  (ptr-read
                                                    (ptr-cast
                                                      (ptr-offset
                                                        dst
                                                        (- copied distance))
                                                      : (Ptr i64)))))
                                              (set! copied (+ copied 8)))))
                                        (let
                                          [copied : i64 0]
                                          (while (< copied length)
                                            (begin
                                              (unsafe
                                                (ptr-write!
                                                  (ptr-offset
                                                    out-data
                                                    (+ out-index copied))
                                                  (ptr-read
                                                    (ptr-offset
                                                      out-data
                                                      (-
                                                        (+ out-index copied)
                                                        distance)))))
                                              (set! copied (+ copied 1))))))
                                      (set! out-index (+ out-index length)))))))]))))
                  (set! consumed (- (* (- next-byte bit-start) 8) available))
                  (when
                    (< out-index raw-len)
                    (begin
                      ;; stage 0: main symbol, 1: distance, 2: length
                      (set! symbol (- 0 1))
                      (when
                        (and
                          (<= consumed fast-limit)
                          (> (array-length main-lookup) 0))
                        (begin
                          (while (< available 16)
                            (begin
                              (set!
                                buffer
                                (bit-or
                                  (shl buffer 8)
                                  (cast (array-ref payload next-byte) : i64)))
                              (set! next-byte (+ next-byte 1))
                              (set! available (+ available 8))))
                          (let
                            [entry : i64
                              (array-ref
                                main-lookup
                                (bit-and (shr buffer (- available 16)) 65535))]
                            (when
                              (> entry 0)
                              (let
                                [length : i64 (shr entry 13)]
                                (begin
                                  (set! available (- available length))
                                  (set! consumed (+ consumed length))
                                  (set! symbol (- (bit-and entry 8191) 1))))))))
                      (when
                        (< symbol 0)
                        (let
                          [reader : CompilerEmbeddedStdlibTlciBitReader
                            (CompilerEmbeddedStdlibTlciBitReader
                              next-byte
                              buffer
                              available
                              consumed)]
                          (match (compiler-embedded-stdlib-tlci-codec-decode-symbol
                            payload
                            bit-len
                            (&mut reader)
                            (& main-table))
                            [(ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Err
                                message)
                              (return
                                (CompilerEmbeddedStdlibTlciCodecBytes.Err
                                  message))]
                            [(ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Ok
                                value)
                              (begin
                                (set! symbol value)
                                (set! next-byte reader.next-byte)
                                (set! buffer reader.buffer)
                                (set! available reader.available)
                                (set! consumed reader.consumed))])))
                      (if (< symbol 256)
                        (begin
                          (set! (array-ref out out-index) (cast symbol : u8))
                          (set! out-index (+ out-index 1)))
                        (begin
                          (set! stage 1)
                          (while (> stage 0)
                            (let
                              [lookup : (__tl_dyn-array i64)
                                (if (= stage 1)
                                  distance-lookup
                                  length-lookup)]
                              [value : i64 (- 0 1)]
                              (begin
                                (when
                                  (and
                                    (<= consumed fast-limit)
                                    (> (array-length lookup) 0))
                                  (begin
                                    (while (< available 16)
                                      (begin
                                        (set!
                                          buffer
                                          (bit-or
                                            (shl buffer 8)
                                            (cast
                                              (array-ref payload next-byte)
                                              : i64)))
                                        (set! next-byte (+ next-byte 1))
                                        (set! available (+ available 8))))
                                    (let
                                      [entry : i64
                                        (array-ref
                                          lookup
                                          (bit-and
                                            (shr buffer (- available 16))
                                            65535))]
                                      (when
                                        (> entry 0)
                                        (let
                                          [length : i64 (shr entry 13)]
                                          (begin
                                            (set!
                                              available
                                              (- available length))
                                            (set! consumed (+ consumed length))
                                            (set!
                                              value
                                              (- (bit-and entry 8191) 1))))))))
                                (when
                                  (< value 0)
                                  (let
                                    [reader : CompilerEmbeddedStdlibTlciBitReader
                                      (CompilerEmbeddedStdlibTlciBitReader
                                        next-byte
                                        buffer
                                        available
                                        consumed)]
                                    (match (compiler-embedded-stdlib-tlci-codec-decode-symbol
                                      payload
                                      bit-len
                                      (&mut reader)
                                      (if (= stage 1)
                                        (& distance-table)
                                        (& length-table)))
                                      [(ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Err
                                          message)
                                        (return
                                          (CompilerEmbeddedStdlibTlciCodecBytes.Err
                                            message))]
                                      [(ResultCompilerEmbeddedStdlibTlciHuffmanSymbol.Ok
                                          v)
                                        (begin
                                          (set! value v)
                                          (set! next-byte reader.next-byte)
                                          (set! buffer reader.buffer)
                                          (set! available reader.available)
                                          (set! consumed reader.consumed))])))
                                (if (= stage 1)
                                  (begin
                                    (set! distance-symbol value)
                                    (set! stage 2))
                                  (let
                                    [distance : i64 (+ distance-symbol 1)]
                                    [length : i64 (+ value 3)]
                                    (begin
                                      (set! stage 0)
                                      (cond
                                        [(> distance out-index)
                                          (return
                                            (CompilerEmbeddedStdlibTlciCodecBytes.Err
                                              "embedded stdlib tlci envelope: backreference before output"))]
                                        [(> length (- raw-len out-index))
                                          (return
                                            (CompilerEmbeddedStdlibTlciCodecBytes.Err
                                              "embedded stdlib tlci envelope: backreference exceeds output"))]
                                        ;; Both ranges were just checked to lie
                                        ;; inside `out`. A source at least eight
                                        ;; bytes back is already written for a whole
                                        ;; word ahead, so words copy it exactly as
                                        ;; the byte loop would; a nearer, overlapping
                                        ;; source and the tail go byte by byte.
                                        [else
                                          (let
                                            [copied : i64 0]
                                            (begin
                                              (when
                                                (>= distance 8)
                                                (let
                                                  [dst : (MutPtr u8)
                                                    (unsafe
                                                      (ptr-offset
                                                        (__tl_array-data out)
                                                        out-index))]
                                                  [words : i64 (- length 7)]
                                                  (while (< copied words)
                                                    (begin
                                                      (unsafe
                                                        (ptr-write!
                                                          (ptr-cast
                                                            (ptr-offset
                                                              dst
                                                              copied)
                                                            : (MutPtr i64))
                                                          (ptr-read
                                                            (ptr-cast
                                                              (ptr-offset
                                                                dst
                                                                (-
                                                                  copied
                                                                  distance))
                                                              : (Ptr i64)))))
                                                      (set! copied (+ copied 8))))))
                                              (while (< copied length)
                                                (begin
                                                  (set!
                                                    (array-ref
                                                      out
                                                      (+ out-index copied))
                                                    (array-ref
                                                      out
                                                      (-
                                                        (+ out-index copied)
                                                        distance)))
                                                  (set! copied (+ copied 1))))
                                              (set!
                                                out-index
                                                (+ out-index length))))]))))))))))))))
            (if (!= consumed bit-len)
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