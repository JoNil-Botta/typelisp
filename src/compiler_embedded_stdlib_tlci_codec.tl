;; Bounded decoder for the compiler-owned embedded stdlib TLCI envelope.
;;
;; The ordinary `.tlci` image remains unchanged. Its existing LZSS token stream
;; is represented here by three canonical Huffman alphabets: literal-or-match,
;; match distance, and match length. Code lengths are stored explicitly so the
;; decoder owns no fixed model and repeated encoder runs are byte-identical.
(import stdlib.iterator)
(import stdlib.byte_le)
(import stdlib.string)
(import compiler_lzss as lzss)
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
    (while (and matches (< index prefix-len))
      (if (!=
        (array-ref payload index)
        (cast (string.string-ref prefix index) : u8))
        (set! matches false)
        unit)
      (+= index 1))
    matches))

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
        (Err "embedded stdlib tlci envelope: invalid raw length limit")]
      [(not (compiler-embedded-stdlib-tlci-codec-prefix? payload prefix))
        (Err "embedded stdlib tlci envelope: bad prefix or version")]
      [(< payload-len header-len)
        (Err "embedded stdlib tlci envelope: truncated header")]
      [(>= (array-ref payload (+ prefix-len 7)) (cast 128 : u8))
        (Err "embedded stdlib tlci envelope: raw length overflows i64")]
      [(>= (array-ref payload (+ prefix-len 15)) (cast 128 : u8))
        (Err "embedded stdlib tlci envelope: bit length overflows i64")]
      [else
        (let
          [raw-len : i64 (byte_le.read-u64 payload prefix-len)]
          [bit-len : i64 (byte_le.read-u64 payload (+ prefix-len 8))]
          [bit-bytes : i64
            (+
              (/ bit-len 8)
              (if (= (% bit-len 8) 0)
                0
                1))]
          [available : i64 (- payload-len header-len)]
          (cond
            [(> raw-len raw-limit)
              (Err
                "embedded stdlib tlci envelope: raw length exceeds consumer limit")]
            [(> bit-bytes available)
              (Err "embedded stdlib tlci envelope: truncated bitstream")]
            [(< bit-bytes available)
              (Err "embedded stdlib tlci envelope: trailing compressed bytes")]
            [(and
                (> bit-bytes 0)
                (!= (% bit-len 8) 0)
                (!=
                  (bit-and
                    (cast (array-ref payload (- payload-len 1)) : i64)
                    (- (shl 1 (- 8 (% bit-len 8))) 1))
                  0))
              (Err "embedded stdlib tlci envelope: nonzero padding bits")]
            [else (Ok raw-len bit-len header-len)]))])))

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
    (for [symbol (iterator.range 0 alphabet-size)]
      (let
        [bits : i64 (cast (array-ref payload (+ start symbol)) : i64)]
        (when
          (> bits (compiler-embedded-stdlib-tlci-codec-max-code-bits))
          (return
            (Err "embedded stdlib tlci envelope: invalid huffman code length")))
        (when
          (> bits 0)
          (set! (array-ref counts bits) (+ (array-ref counts bits) 1))
          (+= active 1)
          (when (> bits max-bits) (set! max-bits bits)))))
    (if (= active 0)
      (Ok
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
        [left : i64 1]
        (for [bits (iterator.range 1 (+ max-bits 1))]
          (set! left (- (* left 2) (array-ref counts bits)))
          (when
            (< left 0)
            (return
              (Err
                "embedded stdlib tlci envelope: oversubscribed huffman table"))))
        (if (!= left 0)
          (Err "embedded stdlib tlci envelope: incomplete huffman table")
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
            (while (<= code-bits max-bits)
              (set! code (shl (+ code (array-ref counts (- code-bits 1))) 1))
              (set! (array-ref first-codes code-bits) code)
              (set! (array-ref first-symbols code-bits) ordered)
              (set! (array-ref next code-bits) ordered)
              (+= ordered (array-ref counts code-bits))
              (+= code-bits 1))
            (for [symbol (iterator.range 0 alphabet-size)]
              (let
                [length : i64 (cast (array-ref payload (+ start symbol)) : i64)]
                (if (> length 0)
                  (let
                    [position : i64 (array-ref next length)]
                    (set! (array-ref symbols position) symbol)
                    (set! (array-ref next length) (+ position 1)))
                  unit)))
            ;; Directly expand all codes up to 16 bits. Main and length
            ;; symbols always fit and effectively all real distance tokens
            ;; do too. Longer malformed/rare tables retain the fallback.
            (set! code-bits 1)
            (while (and
              (<= code-bits max-bits)
              (<= code-bits (compiler-embedded-stdlib-tlci-codec-lookup-bits)))
              (let
                [count : i64 (array-ref counts code-bits)]
                [repeats : i64
                  (shl
                    1
                    (-
                      (compiler-embedded-stdlib-tlci-codec-lookup-bits)
                      code-bits))]
                (for [offset (iterator.range 0 count)]
                  (let
                    [canonical : i64
                      (+ (array-ref first-codes code-bits) offset)]
                    [decoded : i64
                      (array-ref
                        symbols
                        (+ (array-ref first-symbols code-bits) offset))]
                    [base : i64 (* canonical repeats)]
                    [packed : i64 (bit-or (shl code-bits 13) (+ decoded 1))]
                    (for [repeat (iterator.range 0 repeats)]
                      (set! (array-ref lookup (+ base repeat)) packed))))
                (+= code-bits 1)))
            (Ok
              (CompilerEmbeddedStdlibTlciHuffmanTable
                counts
                first-codes
                first-symbols
                symbols
                lookup
                active
                max-bits))))))))

(define (compiler-embedded-stdlib-tlci-codec-decode-symbol
  [payload : (& payload (__tl_dyn-array u8))]
  [bit-len : i64]
  [reader : (&mut reader CompilerEmbeddedStdlibTlciBitReader)]
  [table : (& table CompilerEmbeddedStdlibTlciHuffmanTable)]) : ResultCompilerEmbeddedStdlibTlciHuffmanSymbol
  (if (= table.active 0)
    (Err "embedded stdlib tlci envelope: missing huffman table")
    (begin
      (when
        (>=
          (- bit-len reader.consumed)
          (compiler-embedded-stdlib-tlci-codec-lookup-bits))
        (while (<
          reader.available
          (compiler-embedded-stdlib-tlci-codec-lookup-bits))
          (set!
            reader.buffer
            (bit-or
              (shl reader.buffer 8)
              (cast (array-ref payload reader.next-byte) : i64)))
          (+= reader.next-byte 1)
          (+= reader.available 8))
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
              (set! reader.available remaining)
              (+= reader.consumed length)
              (return (Ok symbol))))))
      (let
        [code : i64 0]
        (for [bits (iterator.range 1 (+ table.max-bits 1))]
          (when
            (>= reader.consumed bit-len)
            (return
              (Err "embedded stdlib tlci envelope: truncated huffman code")))
          (let
            [bit : i64 0]
            (when
              (= reader.available 0)
              (set!
                reader.buffer
                (cast (array-ref payload reader.next-byte) : i64))
              (+= reader.next-byte 1)
              (set! reader.available 8))
            (set! bit (bit-and (shr reader.buffer (- reader.available 1)) 1))
            (-= reader.available 1)
            (+= reader.consumed 1)
            (set! code (bit-or (shl code 1) bit)))
          (let
            [first : i64 (array-ref table.first-codes bits)]
            [count : i64 (array-ref table.counts bits)]
            [offset : i64 (- code first)]
            (when
              (and (>= offset 0) (< offset count))
              (return
                (Ok
                  (array-ref
                    table.symbols
                    (+ (array-ref table.first-symbols bits) offset)))))))
        (Err "embedded stdlib tlci envelope: invalid huffman code")))))

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
        (Err "embedded stdlib tlci envelope: nonempty stream for empty output")]
      [(and
          (= raw-len 0)
          (or
            (> main-table.active 0)
            (> distance-table.active 0)
            (> length-table.active 0)))
        (Err "embedded stdlib tlci envelope: nonempty tables for empty output")]
      [(and (> raw-len 0) (= main-table.active 0))
        (Err "embedded stdlib tlci envelope: missing main huffman table")]
      [(and
          match-present
          (or (= distance-table.active 0) (= length-table.active 0)))
        (Err "embedded stdlib tlci envelope: missing match huffman table")]
      [(and
          (not match-present)
          (or (> distance-table.active 0) (> length-table.active 0)))
        (Err "embedded stdlib tlci envelope: unexpected match huffman table")]
      [else
        ;; The bit reader lives in locals and a symbol whose 16-bit prefix hits
        ;; its table's direct entry is decoded right here, exactly as the first
        ;; branch of decode-symbol would; every other symbol -- a longer code,
        ;; or one within 16 bits of the stream's end -- goes through
        ;; decode-symbol itself on a reader rebuilt from the locals, so the
        ;; call, its Result and a reader behind a reference are not paid once
        ;; per symbol of a multi-megabyte image.
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
          ;; Fast phase, while at least 16 bitstream bytes are unread. One
          ;; refill to 48+ bits then covers a whole token -- a literal, or a
          ;; match's three codes of at most 16 bits each -- and every direct
          ;; read is in range: each table holds exactly lookup-size entries
          ;; and its index is 16 bits. A token that needs anything else (a
          ;; longer code, or a match the general loop would reject) leaves
          ;; this loop before consuming a bit, and the general loop below
          ;; decodes it, errors included.
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
            [payload-view : (__tl_dyn-array u8)
              (owned_view.compiler-owned-reference-shared-view payload)]
            [payload-data : (Ptr u8)
              (unsafe
                (ptr-cast (__tl_array-data payload-view) : (Ptr u8)))]
            [out-data : (MutPtr u8)
              (unsafe
                (__tl_array-data out))]
            [main-data : (MutPtr i64)
              (unsafe
                (__tl_array-data main-lookup))]
            [distance-data : (MutPtr i64)
              (unsafe
                (__tl_array-data distance-lookup))]
            [length-data : (MutPtr i64)
              (unsafe
                (__tl_array-data length-lookup))]
            (while (< out-index raw-len)
              (set! fast? (and tables-ok? (>= next-byte 0)))
              (while (and fast? (< out-index raw-len) (<= next-byte byte-limit))
                (when
                  (< available 48)
                  (while (<= available 56)
                    (set!
                      buffer
                      (bit-or
                        (shl buffer 8)
                        ;; This refill reads at most eight bytes.
                        ;; The enclosing guard proves sixteen remain,
                        ;; so every byte is within the payload.
                        (cast
                          (unsafe
                            (ptr-read (ptr-offset payload-data next-byte)))
                          : i64)))
                    (+= next-byte 1)
                    (+= available 8)))
                ;; 48 <= available <= 64 here, so every shift count below
                ;; is in [0, 48] on the paths that use it.
                (let
                  [entry : i64
                    (unsafe
                      (ptr-read
                        (ptr-offset
                          main-data
                          (bit-and
                            (shr buffer (bit-and (- available 16) 63))
                            65535))))]
                  (cond
                    [(<= entry 0) (set! fast? false)]
                    [(< (bit-and entry 8191) 257)
                      (unsafe
                        (ptr-write!
                          (ptr-offset out-data out-index)
                          (cast (- (bit-and entry 8191) 1) : u8)))
                      (+= out-index 1)
                      (-= available (shr entry 13))]
                    [else
                      (let
                        [after-main : i64 (- available (shr entry 13))]
                        [distance-entry : i64
                          (unsafe
                            (ptr-read
                              (ptr-offset
                                distance-data
                                (bit-and
                                  (shr buffer (bit-and (- after-main 16) 63))
                                  65535))))]
                        (if (<= distance-entry 0)
                          (set! fast? false)
                          (let
                            [after-distance : i64
                              (- after-main (shr distance-entry 13))]
                            [length-entry : i64
                              (unsafe
                                (ptr-read
                                  (ptr-offset
                                    length-data
                                    (bit-and
                                      (shr
                                        buffer
                                        (bit-and (- after-distance 16) 63))
                                      65535))))]
                            ;; symbol + 1 is the low field: distance is the
                            ;; distance symbol + 1, length the symbol + 3.
                            [distance : i64 (bit-and distance-entry 8191)]
                            [length : i64 (+ (bit-and length-entry 8191) 2)]
                            (if (or
                              (<= length-entry 0)
                              (> distance out-index)
                              (> length (- raw-len out-index)))
                              (set! fast? false)
                              (begin
                                (set!
                                  available
                                  (- after-distance (shr length-entry 13)))
                                (lzss.compiler-lzss-copy-match!
                                  out-data
                                  out-index
                                  distance
                                  length)
                                (+= out-index length))))))])))
              (set! consumed (- (* (- next-byte bit-start) 8) available))
              (when
                (< out-index raw-len)
                ;; stage 0: main symbol, 1: distance, 2: length
                (set! symbol (- 0 1))
                (when
                  (and
                    (<= consumed fast-limit)
                    (> (array-length main-lookup) 0))
                  (while (< available 16)
                    (set!
                      buffer
                      (bit-or
                        (shl buffer 8)
                        (cast (array-ref payload next-byte) : i64)))
                    (+= next-byte 1)
                    (+= available 8))
                  (let
                    [entry : i64
                      (array-ref
                        main-lookup
                        (bit-and (shr buffer (- available 16)) 65535))]
                    (when
                      (> entry 0)
                      (let
                        [length : i64 (shr entry 13)]
                        (-= available length)
                        (+= consumed length)
                        (set! symbol (- (bit-and entry 8191) 1))))))
                (when
                  (< symbol 0)
                  (let
                    [reader : CompilerEmbeddedStdlibTlciBitReader
                      (CompilerEmbeddedStdlibTlciBitReader
                        next-byte
                        buffer
                        available
                        consumed)]
                    [value
                      (try
                        (compiler-embedded-stdlib-tlci-codec-decode-symbol
                          payload
                          bit-len
                          (&mut reader)
                          (& main-table)))]
                    (set! symbol value)
                    (set! next-byte reader.next-byte)
                    (set! buffer reader.buffer)
                    (set! available reader.available)
                    (set! consumed reader.consumed)))
                (if (< symbol 256)
                  (begin
                    (set! (array-ref out out-index) (cast symbol : u8))
                    (+= out-index 1))
                  (begin
                    (set! stage 1)
                    (while (> stage 0)
                      (let
                        [lookup : (__tl_dyn-array i64)
                          (if (= stage 1)
                            (owned_view.compiler-owned-shared-view
                              distance-lookup)
                            (owned_view.compiler-owned-shared-view
                              length-lookup))]
                        [value : i64 (- 0 1)]
                        (when
                          (and
                            (<= consumed fast-limit)
                            (> (array-length lookup) 0))
                          (while (< available 16)
                            (set!
                              buffer
                              (bit-or
                                (shl buffer 8)
                                (cast (array-ref payload next-byte) : i64)))
                            (+= next-byte 1)
                            (+= available 8))
                          (let
                            [entry : i64
                              (array-ref
                                lookup
                                (bit-and (shr buffer (- available 16)) 65535))]
                            (when
                              (> entry 0)
                              (let
                                [length : i64 (shr entry 13)]
                                (-= available length)
                                (+= consumed length)
                                (set! value (- (bit-and entry 8191) 1))))))
                        (when
                          (< value 0)
                          (let
                            [reader : CompilerEmbeddedStdlibTlciBitReader
                              (CompilerEmbeddedStdlibTlciBitReader
                                next-byte
                                buffer
                                available
                                consumed)]
                            [v
                              (try
                                (compiler-embedded-stdlib-tlci-codec-decode-symbol
                                  payload
                                  bit-len
                                  (&mut reader)
                                  (if (= stage 1)
                                    (& distance-table)
                                    (& length-table))))]
                            (set! value v)
                            (set! next-byte reader.next-byte)
                            (set! buffer reader.buffer)
                            (set! available reader.available)
                            (set! consumed reader.consumed)))
                        (if (= stage 1)
                          (begin
                            (set! distance-symbol value)
                            (set! stage 2))
                          (let
                            [distance : i64 (+ distance-symbol 1)]
                            [length : i64 (+ value 3)]
                            (set! stage 0)
                            (cond
                              [(> distance out-index)
                                (return
                                  (Err
                                    "embedded stdlib tlci envelope: backreference before output"))]
                              [(> length (- raw-len out-index))
                                (return
                                  (Err
                                    "embedded stdlib tlci envelope: backreference exceeds output"))]
                              [else
                                (lzss.compiler-lzss-copy-match!
                                  (unsafe
                                    (__tl_array-data out))
                                  out-index
                                  distance
                                  length)
                                (+= out-index length)]))))))))))
          (if (!= consumed bit-len)
            (Err "embedded stdlib tlci envelope: trailing huffman bits")
            (Ok out)))])))

;: Decode one complete embedded-image envelope after fail-closed validation.
(define (compiler-embedded-stdlib-tlci-codec-decode
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : CompilerEmbeddedStdlibTlciCodecBytes
  (match (compiler-embedded-stdlib-tlci-codec-frame payload raw-limit)
    [(Err message) (Err message)]
    [(Ok raw-len bit-len bit-start)
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
        [main-table
          (try
            (compiler-embedded-stdlib-tlci-codec-build-table
              payload
              main-start
              (compiler-embedded-stdlib-tlci-codec-main-symbols)))]
        [distance-table
          (try
            (compiler-embedded-stdlib-tlci-codec-build-table
              payload
              distance-start
              (compiler-embedded-stdlib-tlci-codec-distance-symbols)))]
        [length-table
          (try
            (compiler-embedded-stdlib-tlci-codec-build-table
              payload
              length-start
              (compiler-embedded-stdlib-tlci-codec-length-symbols)))]
        (compiler-embedded-stdlib-tlci-codec-decode-with-tables
          payload
          raw-len
          bit-len
          bit-start
          main-start
          main-table
          distance-table
          length-table))]))