;; Deterministic build-time encoder for the embedded stdlib TLCI envelope.
;; This module is used by the payload builder and is not linked into `typelisp`.
(import compiler_ctfe as ctfe)
(import stdlib.byte_buf_core)
(import stdlib.string)

(define (compiler-embedded-stdlib-tlci-encoder-prefix) : String
  "__typelisp_embedded_stdlib_tlch_v1__")

(define (compiler-embedded-stdlib-tlci-encoder-lzss-prefix) : String
  "__typelisp_embedded_stdlib_lzss_v1__")

(define (compiler-embedded-stdlib-tlci-encoder-main-symbols) : i64
  257)

(define (compiler-embedded-stdlib-tlci-encoder-distance-symbols) : i64
  4096)

(define (compiler-embedded-stdlib-tlci-encoder-length-symbols) : i64
  16)

(define (compiler-embedded-stdlib-tlci-encoder-max-code-bits) : i64
  31)

(defstruct CompilerEmbeddedStdlibTlciEncoderFrequencies
  (raw-len i64)
  (token-start i64)
  (main (__tl_dyn-array i64))
  (distance (__tl_dyn-array i64))
  (length (__tl_dyn-array i64)))

(defenum ResultCompilerEmbeddedStdlibTlciEncoderFrequencies
  (Err String)
  (Ok CompilerEmbeddedStdlibTlciEncoderFrequencies))

(defstruct CompilerEmbeddedStdlibTlciEncoderCodes
  (lengths (__tl_dyn-array i64))
  (codes (__tl_dyn-array i64)))

(defenum ResultCompilerEmbeddedStdlibTlciEncoderCodes
  (Err String)
  (Ok CompilerEmbeddedStdlibTlciEncoderCodes))

(defenum ResultCompilerEmbeddedStdlibTlciEncoderBytes
  (Err String)
  (Ok (__tl_dyn-array u8)))

(defstruct CompilerEmbeddedStdlibTlciEncoderHeap
  (nodes (__tl_dyn-array i64))
  (len i64))

(defstruct CompilerEmbeddedStdlibTlciEncoderBitWriter
  (out byte_buf_core.ByteBufBuilder)
  (current i64)
  (used i64)
  (bits i64))

(define (compiler-embedded-stdlib-tlci-encoder-byte
  [data : (& data str)]
  [index : i64]) : i64
  (cast (string.string-ref data index) : i64))

(define (compiler-embedded-stdlib-tlci-encoder-prefix?
  [data : (& data str)]
  [prefix : (& prefix str)]) : bool
  (let
    [index : i64 0]
    [prefix-len : i64 (string.string-length prefix)]
    [matches : bool (>= (string.string-length data) prefix-len)]
    (begin
      (while (and matches (< index prefix-len))
        (begin
          (if (!=
            (string.string-ref data index)
            (string.string-ref prefix index))
            (set! matches false)
            unit)
          (set! index (+ index 1))))
      matches)))

(define (compiler-embedded-stdlib-tlci-encoder-count [lzss : (& lzss str)]) : ResultCompilerEmbeddedStdlibTlciEncoderFrequencies
  (let
    [prefix : String (compiler-embedded-stdlib-tlci-encoder-lzss-prefix)]
    [prefix-len : i64 (string.string-length prefix)]
    [lzss-len : i64 (string.string-length lzss)]
    (if (not (compiler-embedded-stdlib-tlci-encoder-prefix? lzss (& prefix)))
      (ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Err
        "embedded stdlib tlci encoder: bad lzss prefix")
      (let
        [index : i64 prefix-len]
        [raw-len : i64 0]
        [digits : i64 0]
        [overflow : bool false]
        [max-i64 : i64 9223372036854775807]
        (begin
          (while (and
            (not overflow)
            (< index lzss-len)
            (>= (compiler-embedded-stdlib-tlci-encoder-byte lzss index) 48)
            (<= (compiler-embedded-stdlib-tlci-encoder-byte lzss index) 57))
            (let
              [digit : i64
                (- (compiler-embedded-stdlib-tlci-encoder-byte lzss index) 48)]
              (begin
                (if (> raw-len (/ (- max-i64 digit) 10))
                  (set! overflow true)
                  (set! raw-len (+ (* raw-len 10) digit)))
                (set! digits (+ digits 1))
                (set! index (+ index 1)))))
          (cond
            [overflow
              (ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Err
                "embedded stdlib tlci encoder: lzss raw length overflows i64")]
            [(= digits 0)
              (ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Err
                "embedded stdlib tlci encoder: missing lzss raw length")]
            [(or
                (>= index lzss-len)
                (!= (compiler-embedded-stdlib-tlci-encoder-byte lzss index) 10))
              (ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Err
                "embedded stdlib tlci encoder: malformed lzss raw length")]
            [else
              (let
                [token-start : i64 (+ index 1)]
                [main : (__tl_dyn-array i64)
                  (__tl_make-array
                    i64
                    (compiler-embedded-stdlib-tlci-encoder-main-symbols))]
                [distance : (__tl_dyn-array i64)
                  (__tl_make-array
                    i64
                    (compiler-embedded-stdlib-tlci-encoder-distance-symbols))]
                [length : (__tl_dyn-array i64)
                  (__tl_make-array
                    i64
                    (compiler-embedded-stdlib-tlci-encoder-length-symbols))]
                [token-index : i64 token-start]
                [out-index : i64 0]
                (begin
                  (while (< out-index raw-len)
                    (begin
                      (when
                        (>= token-index lzss-len)
                        (return
                          (ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Err
                            "embedded stdlib tlci encoder: truncated lzss flags")))
                      (let
                        [flags : i64
                          (compiler-embedded-stdlib-tlci-encoder-byte
                            lzss
                            token-index)]
                        [bit : i64 0]
                        (begin
                          (set! token-index (+ token-index 1))
                          (while (and (< bit 8) (< out-index raw-len))
                            (begin
                              (if (!= (bit-and flags (shl 1 bit)) 0)
                                (begin
                                  (when
                                    (>= token-index lzss-len)
                                    (return
                                      (ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Err
                                        "embedded stdlib tlci encoder: truncated lzss literal")))
                                  (let
                                    [literal : i64
                                      (compiler-embedded-stdlib-tlci-encoder-byte
                                        lzss
                                        token-index)]
                                    (begin
                                      (set!
                                        (array-ref main literal)
                                        (+ (array-ref main literal) 1))
                                      (set! token-index (+ token-index 1))
                                      (set! out-index (+ out-index 1)))))
                                (begin
                                  (when
                                    (> (+ token-index 2) lzss-len)
                                    (return
                                      (ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Err
                                        "embedded stdlib tlci encoder: truncated lzss match")))
                                  (let
                                    [packed : i64
                                      (bit-or
                                        (shl
                                          (compiler-embedded-stdlib-tlci-encoder-byte
                                            lzss
                                            token-index)
                                          8)
                                        (compiler-embedded-stdlib-tlci-encoder-byte
                                          lzss
                                          (+ token-index 1)))]
                                    [distance-symbol : i64 (shr packed 4)]
                                    [length-symbol : i64 (bit-and packed 15)]
                                    [match-length : i64 (+ length-symbol 3)]
                                    (begin
                                      (when
                                        (> (+ distance-symbol 1) out-index)
                                        (return
                                          (ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Err
                                            "embedded stdlib tlci encoder: lzss match before output")))
                                      (when
                                        (> (+ out-index match-length) raw-len)
                                        (return
                                          (ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Err
                                            "embedded stdlib tlci encoder: lzss match exceeds output")))
                                      (set!
                                        (array-ref main 256)
                                        (+ (array-ref main 256) 1))
                                      (set!
                                        (array-ref distance distance-symbol)
                                        (+
                                          (array-ref distance distance-symbol)
                                          1))
                                      (set!
                                        (array-ref length length-symbol)
                                        (+ (array-ref length length-symbol) 1))
                                      (set! token-index (+ token-index 2))
                                      (set!
                                        out-index
                                        (+ out-index match-length))))))
                              (set! bit (+ bit 1))))))))
                  (if (!= token-index lzss-len)
                    (ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Err
                      "embedded stdlib tlci encoder: trailing lzss tokens")
                    (ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Ok
                      (CompilerEmbeddedStdlibTlciEncoderFrequencies
                        raw-len
                        token-start
                        main
                        distance
                        length)))))]))))))

(define (compiler-embedded-stdlib-tlci-encoder-node-less?
  [left : i64]
  [right : i64]
  [weights : (& weights (__tl_dyn-array i64))]
  [minimums : (& minimums (__tl_dyn-array i64))]) : bool
  (or
    (< (array-ref weights left) (array-ref weights right))
    (and
      (= (array-ref weights left) (array-ref weights right))
      (or
        (< (array-ref minimums left) (array-ref minimums right))
        (and
          (= (array-ref minimums left) (array-ref minimums right))
          (< left right))))))

(define (compiler-embedded-stdlib-tlci-encoder-heap-push!
  [heap : (&mut heap CompilerEmbeddedStdlibTlciEncoderHeap)]
  [node : i64]
  [weights : (& weights (__tl_dyn-array i64))]
  [minimums : (& minimums (__tl_dyn-array i64))]) : unit
  (let
    [position : i64 heap.len]
    [done : bool false]
    (begin
      (set! heap.len (+ heap.len 1))
      (while (and (> position 0) (not done))
        (let
          [parent : i64 (/ (- position 1) 2)]
          [parent-node : i64 (array-ref heap.nodes parent)]
          (if (compiler-embedded-stdlib-tlci-encoder-node-less?
            node
            parent-node
            weights
            minimums)
            (begin
              (set! (array-ref heap.nodes position) parent-node)
              (set! position parent))
            (set! done true))))
      (set! (array-ref heap.nodes position) node))))

(define (compiler-embedded-stdlib-tlci-encoder-heap-pop!
  [heap : (&mut heap CompilerEmbeddedStdlibTlciEncoderHeap)]
  [weights : (& weights (__tl_dyn-array i64))]
  [minimums : (& minimums (__tl_dyn-array i64))]) : i64
  (let
    [root : i64 (array-ref heap.nodes 0)]
    [new-len : i64 (- heap.len 1)]
    (begin
      (set! heap.len new-len)
      (if (> new-len 0)
        (let
          [node : i64 (array-ref heap.nodes new-len)]
          [position : i64 0]
          [done : bool false]
          (begin
            (while (not done)
              (let
                [left : i64 (+ (* position 2) 1)]
                (if (>= left new-len)
                  (set! done true)
                  (let
                    [right : i64 (+ left 1)]
                    [child : i64
                      (if (and
                        (< right new-len)
                        (compiler-embedded-stdlib-tlci-encoder-node-less?
                          (array-ref heap.nodes right)
                          (array-ref heap.nodes left)
                          weights
                          minimums))
                        right
                        left)]
                    [child-node : i64 (array-ref heap.nodes child)]
                    (if (compiler-embedded-stdlib-tlci-encoder-node-less?
                      child-node
                      node
                      weights
                      minimums)
                      (begin
                        (set! (array-ref heap.nodes position) child-node)
                        (set! position child))
                      (set! done true))))))
            (set! (array-ref heap.nodes position) node)))
        unit)
      root)))

(define (compiler-embedded-stdlib-tlci-encoder-canonical-codes
  [lengths : (__tl_dyn-array i64)]) : CompilerEmbeddedStdlibTlciEncoderCodes
  (let
    [counts : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (+ (compiler-embedded-stdlib-tlci-encoder-max-code-bits) 1))]
    [next : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (+ (compiler-embedded-stdlib-tlci-encoder-max-code-bits) 1))]
    [codes : (__tl_dyn-array i64) (__tl_make-array i64 (array-length lengths))]
    [symbol : i64 0]
    (begin
      (while (< symbol (array-length lengths))
        (let
          [bits : i64 (array-ref lengths symbol)]
          (begin
            (if (> bits 0)
              (set! (array-ref counts bits) (+ (array-ref counts bits) 1))
              unit)
            (set! symbol (+ symbol 1)))))
      (let
        [bits : i64 1]
        [code : i64 0]
        (while (<= bits (compiler-embedded-stdlib-tlci-encoder-max-code-bits))
          (begin
            (set! code (shl (+ code (array-ref counts (- bits 1))) 1))
            (set! (array-ref next bits) code)
            (set! bits (+ bits 1)))))
      (set! symbol 0)
      (while (< symbol (array-length lengths))
        (let
          [bits : i64 (array-ref lengths symbol)]
          (begin
            (if (> bits 0)
              (begin
                (set! (array-ref codes symbol) (array-ref next bits))
                (set! (array-ref next bits) (+ (array-ref next bits) 1)))
              unit)
            (set! symbol (+ symbol 1)))))
      (CompilerEmbeddedStdlibTlciEncoderCodes lengths codes))))

(define (compiler-embedded-stdlib-tlci-encoder-build-codes
  [frequencies : (__tl_dyn-array i64)]) : ResultCompilerEmbeddedStdlibTlciEncoderCodes
  (let
    [alphabet-size : i64 (array-length frequencies)]
    [node-capacity : i64 (* alphabet-size 2)]
    [weights : (__tl_dyn-array i64) (__tl_make-array i64 node-capacity)]
    [minimums : (__tl_dyn-array i64) (__tl_make-array i64 node-capacity)]
    [parents : (__tl_dyn-array i64) (__tl_make-array i64 node-capacity)]
    [heap : CompilerEmbeddedStdlibTlciEncoderHeap
      (CompilerEmbeddedStdlibTlciEncoderHeap
        (__tl_make-array i64 node-capacity)
        0)]
    [lengths : (__tl_dyn-array i64) (__tl_make-array i64 alphabet-size)]
    [symbol : i64 0]
    [active : i64 0]
    [only : i64 -1]
    (begin
      (while (< symbol alphabet-size)
        (begin
          (set! (array-ref parents symbol) -1)
          (if (> (array-ref frequencies symbol) 0)
            (begin
              (set! (array-ref weights symbol) (array-ref frequencies symbol))
              (set! (array-ref minimums symbol) symbol)
              (compiler-embedded-stdlib-tlci-encoder-heap-push!
                (&mut heap)
                symbol
                (& weights)
                (& minimums))
              (set! active (+ active 1))
              (set! only symbol))
            unit)
          (set! symbol (+ symbol 1))))
      (cond
        [(= active 0)
          (ResultCompilerEmbeddedStdlibTlciEncoderCodes.Ok
            (compiler-embedded-stdlib-tlci-encoder-canonical-codes lengths))]
        [(= active 1)
          (let
            [dummy : i64
              (if (= only 0)
                1
                0)]
            (begin
              (set! (array-ref lengths only) 1)
              (set! (array-ref lengths dummy) 1)
              (ResultCompilerEmbeddedStdlibTlciEncoderCodes.Ok
                (compiler-embedded-stdlib-tlci-encoder-canonical-codes lengths))))]
        [else
          (let
            [node : i64 alphabet-size]
            (begin
              (while (> heap.len 1)
                (let
                  [left : i64
                    (compiler-embedded-stdlib-tlci-encoder-heap-pop!
                      (&mut heap)
                      (& weights)
                      (& minimums))]
                  [right : i64
                    (compiler-embedded-stdlib-tlci-encoder-heap-pop!
                      (&mut heap)
                      (& weights)
                      (& minimums))]
                  (begin
                    (set!
                      (array-ref weights node)
                      (+ (array-ref weights left) (array-ref weights right)))
                    (set!
                      (array-ref minimums node)
                      (if (<
                        (array-ref minimums left)
                        (array-ref minimums right))
                        (array-ref minimums left)
                        (array-ref minimums right)))
                    (set! (array-ref parents left) node)
                    (set! (array-ref parents right) node)
                    (set! (array-ref parents node) -1)
                    (compiler-embedded-stdlib-tlci-encoder-heap-push!
                      (&mut heap)
                      node
                      (& weights)
                      (& minimums))
                    (set! node (+ node 1)))))
              (set! symbol 0)
              (while (< symbol alphabet-size)
                (begin
                  (if (> (array-ref frequencies symbol) 0)
                    (let
                      [cursor : i64 symbol]
                      [bits : i64 0]
                      (begin
                        (while (>= (array-ref parents cursor) 0)
                          (begin
                            (set! cursor (array-ref parents cursor))
                            (set! bits (+ bits 1))))
                        (when
                          (>
                            bits
                            (compiler-embedded-stdlib-tlci-encoder-max-code-bits))
                          (return
                            (ResultCompilerEmbeddedStdlibTlciEncoderCodes.Err
                              "embedded stdlib tlci encoder: huffman code exceeds 31 bits")))
                        (set! (array-ref lengths symbol) bits)))
                    unit)
                  (set! symbol (+ symbol 1))))
              (ResultCompilerEmbeddedStdlibTlciEncoderCodes.Ok
                (compiler-embedded-stdlib-tlci-encoder-canonical-codes lengths))))]))))

(define (compiler-embedded-stdlib-tlci-encoder-write-code!
  [writer : (&mut writer CompilerEmbeddedStdlibTlciEncoderBitWriter)]
  [code : i64]
  [length : i64]) : unit
  (let
    [bit : i64 (- length 1)]
    (while (>= bit 0)
      (begin
        (set!
          writer.current
          (bit-or (shl writer.current 1) (bit-and (shr code bit) 1)))
        (set! writer.used (+ writer.used 1))
        (set! writer.bits (+ writer.bits 1))
        (if (= writer.used 8)
          (begin
            (byte_buf_core.byte-buf-builder-push
              (&mut writer.out)
              (cast writer.current : u8))
            (set! writer.current 0)
            (set! writer.used 0))
          unit)
        (set! bit (- bit 1))))))

(define (compiler-embedded-stdlib-tlci-encoder-write-symbol!
  [writer : (&mut writer CompilerEmbeddedStdlibTlciEncoderBitWriter)]
  [codes : (& codes CompilerEmbeddedStdlibTlciEncoderCodes)]
  [symbol : i64]) : unit
  (compiler-embedded-stdlib-tlci-encoder-write-code!
    writer
    (array-ref codes.codes symbol)
    (array-ref codes.lengths symbol)))

(define (compiler-embedded-stdlib-tlci-encoder-finish-bits!
  [writer : (&mut writer CompilerEmbeddedStdlibTlciEncoderBitWriter)]) : unit
  (if (> writer.used 0)
    (begin
      (byte_buf_core.byte-buf-builder-push
        (&mut writer.out)
        (cast (shl writer.current (- 8 writer.used)) : u8))
      (set! writer.current 0)
      (set! writer.used 0))
    unit))

(define (compiler-embedded-stdlib-tlci-encoder-encode-tokens
  [lzss : (& lzss str)]
  [frequencies : (& frequencies CompilerEmbeddedStdlibTlciEncoderFrequencies)]
  [main-codes : (& main-codes CompilerEmbeddedStdlibTlciEncoderCodes)]
  [distance-codes : (& distance-codes CompilerEmbeddedStdlibTlciEncoderCodes)]
  [length-codes : (& length-codes CompilerEmbeddedStdlibTlciEncoderCodes)]) : CompilerEmbeddedStdlibTlciEncoderBitWriter
  (let
    [writer : CompilerEmbeddedStdlibTlciEncoderBitWriter
      (CompilerEmbeddedStdlibTlciEncoderBitWriter
        (byte_buf_core.byte-buf-builder-with-capacity
          (+ (/ (string.string-length lzss) 2) 1))
        0
        0
        0)]
    [token-index : i64 frequencies.token-start]
    [out-index : i64 0]
    (begin
      (while (< out-index frequencies.raw-len)
        (let
          [flags : i64
            (compiler-embedded-stdlib-tlci-encoder-byte lzss token-index)]
          [bit : i64 0]
          (begin
            (set! token-index (+ token-index 1))
            (while (and (< bit 8) (< out-index frequencies.raw-len))
              (begin
                (if (!= (bit-and flags (shl 1 bit)) 0)
                  (let
                    [literal : i64
                      (compiler-embedded-stdlib-tlci-encoder-byte
                        lzss
                        token-index)]
                    (begin
                      (compiler-embedded-stdlib-tlci-encoder-write-symbol!
                        (&mut writer)
                        main-codes
                        literal)
                      (set! token-index (+ token-index 1))
                      (set! out-index (+ out-index 1))))
                  (let
                    [packed : i64
                      (bit-or
                        (shl
                          (compiler-embedded-stdlib-tlci-encoder-byte
                            lzss
                            token-index)
                          8)
                        (compiler-embedded-stdlib-tlci-encoder-byte
                          lzss
                          (+ token-index 1)))]
                    [distance-symbol : i64 (shr packed 4)]
                    [length-symbol : i64 (bit-and packed 15)]
                    (begin
                      (compiler-embedded-stdlib-tlci-encoder-write-symbol!
                        (&mut writer)
                        main-codes
                        256)
                      (compiler-embedded-stdlib-tlci-encoder-write-symbol!
                        (&mut writer)
                        distance-codes
                        distance-symbol)
                      (compiler-embedded-stdlib-tlci-encoder-write-symbol!
                        (&mut writer)
                        length-codes
                        length-symbol)
                      (set! token-index (+ token-index 2))
                      (set! out-index (+ out-index (+ length-symbol 3))))))
                (set! bit (+ bit 1)))))))
      (compiler-embedded-stdlib-tlci-encoder-finish-bits! (&mut writer))
      writer)))

(define (compiler-embedded-stdlib-tlci-encoder-push-i64-le!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (let
    [index : i64 0]
    (while (< index 8)
      (begin
        (byte_buf_core.byte-buf-builder-push
          out
          (cast (bit-and (shr value (* index 8)) 255) : u8))
        (set! index (+ index 1))))))

(define (compiler-embedded-stdlib-tlci-encoder-append-lengths!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [codes : (& codes CompilerEmbeddedStdlibTlciEncoderCodes)]) : unit
  (let
    [symbol : i64 0]
    (while (< symbol (array-length codes.lengths))
      (begin
        (byte_buf_core.byte-buf-builder-push
          out
          (cast (array-ref codes.lengths symbol) : u8))
        (set! symbol (+ symbol 1))))))

(define (compiler-embedded-stdlib-tlci-encoder-finish
  [frequencies : (& frequencies CompilerEmbeddedStdlibTlciEncoderFrequencies)]
  [main-codes : (& main-codes CompilerEmbeddedStdlibTlciEncoderCodes)]
  [distance-codes : (& distance-codes CompilerEmbeddedStdlibTlciEncoderCodes)]
  [length-codes : (& length-codes CompilerEmbeddedStdlibTlciEncoderCodes)]
  [writer : (& writer CompilerEmbeddedStdlibTlciEncoderBitWriter)]) : (__tl_dyn-array
    u8)
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity
        (+
          (string.string-length (compiler-embedded-stdlib-tlci-encoder-prefix))
          (+ 4385 (byte_buf_core.byte-buf-builder-len (& writer.out)))))]
    (begin
      (byte_buf_core.byte-buf-builder-append-string
        (&mut out)
        (compiler-embedded-stdlib-tlci-encoder-prefix))
      (compiler-embedded-stdlib-tlci-encoder-push-i64-le!
        (&mut out)
        frequencies.raw-len)
      (compiler-embedded-stdlib-tlci-encoder-push-i64-le!
        (&mut out)
        writer.bits)
      (compiler-embedded-stdlib-tlci-encoder-append-lengths!
        (&mut out)
        main-codes)
      (compiler-embedded-stdlib-tlci-encoder-append-lengths!
        (&mut out)
        distance-codes)
      (compiler-embedded-stdlib-tlci-encoder-append-lengths!
        (&mut out)
        length-codes)
      (byte_buf_core.byte-buf-builder-append-array-range
        (&mut out)
        (& writer.out.slots)
        0
        writer.out.len)
      (byte_buf_core.byte-buf-builder-to-array (& out)))))

;: Encode exact TLCI bytes through the proven LZSS matcher and canonical layer.
(define (compiler-embedded-stdlib-tlci-encoder-encode [source : String]) : ResultCompilerEmbeddedStdlibTlciEncoderBytes
  (let
    [lzss : String (ctfe.ctfe-embedded-stdlib-binary-data-bytes source)]
    (match (compiler-embedded-stdlib-tlci-encoder-count (& lzss))
      [(ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Err message)
        (ResultCompilerEmbeddedStdlibTlciEncoderBytes.Err message)]
      [(ResultCompilerEmbeddedStdlibTlciEncoderFrequencies.Ok frequencies)
        (match (compiler-embedded-stdlib-tlci-encoder-build-codes
          frequencies.main)
          [(ResultCompilerEmbeddedStdlibTlciEncoderCodes.Err message)
            (ResultCompilerEmbeddedStdlibTlciEncoderBytes.Err message)]
          [(ResultCompilerEmbeddedStdlibTlciEncoderCodes.Ok main-codes)
            (match (compiler-embedded-stdlib-tlci-encoder-build-codes
              frequencies.distance)
              [(ResultCompilerEmbeddedStdlibTlciEncoderCodes.Err message)
                (ResultCompilerEmbeddedStdlibTlciEncoderBytes.Err message)]
              [(ResultCompilerEmbeddedStdlibTlciEncoderCodes.Ok distance-codes)
                (match (compiler-embedded-stdlib-tlci-encoder-build-codes
                  frequencies.length)
                  [(ResultCompilerEmbeddedStdlibTlciEncoderCodes.Err message)
                    (ResultCompilerEmbeddedStdlibTlciEncoderBytes.Err message)]
                  [(ResultCompilerEmbeddedStdlibTlciEncoderCodes.Ok
                      length-codes)
                    (let
                      [writer : CompilerEmbeddedStdlibTlciEncoderBitWriter
                        (compiler-embedded-stdlib-tlci-encoder-encode-tokens
                          (& lzss)
                          (& frequencies)
                          (& main-codes)
                          (& distance-codes)
                          (& length-codes))]
                      (ResultCompilerEmbeddedStdlibTlciEncoderBytes.Ok
                        (compiler-embedded-stdlib-tlci-encoder-finish
                          (& frequencies)
                          (& main-codes)
                          (& distance-codes)
                          (& length-codes)
                          (& writer))))])])])])))