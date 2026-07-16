;; compiler_embedded_stdlib.tl - Exact-source compressed stdlib fallback.
(cfg
  (any stage0-seed-bootstrap test)
  (import compiler_embedded_stdlib_payload_seed as payload))
(cfg
  (not (any stage0-seed-bootstrap test))
  (import compiler_embedded_stdlib_payload as payload))
(import stdlib.array)
(import stdlib.string)

(defenum CompilerEmbeddedStdlibSource
  (CompilerEmbeddedStdlibNoSource)
  (CompilerEmbeddedStdlibSomeSource String))

(defenum CompilerEmbeddedStdlibCompressedHeader
  (CompilerEmbeddedStdlibCompressedHeaderInvalid)
  (CompilerEmbeddedStdlibCompressedHeaderValid i64 i64))

(define (compiler-embedded-stdlib-compressed-prefix) : String
  "__typelisp_embedded_stdlib_lzss_v1__")

(define (compiler-embedded-stdlib-payload-prefix?
  [payload : (& payload (Array u8))]
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

(define (compiler-embedded-stdlib-compressed-header
  [payload : (& payload (Array u8))]
  [start : i64]) : CompilerEmbeddedStdlibCompressedHeader
  (let
    [index : i64 start]
    [raw-len : i64 0]
    [valid : bool false]
    (begin
      (while (and
        (< index (array-length payload))
        (>= (array-ref payload index) (cast 48 : u8))
        (<= (array-ref payload index) (cast 57 : u8)))
        (begin
          (set!
            raw-len
            (+ (* raw-len 10) (- (cast (array-ref payload index) : i64) 48)))
          (set! index (+ index 1))))
      (if (and
        (> index start)
        (< index (array-length payload))
        (= (array-ref payload index) (cast 10 : u8)))
        (set! valid true)
        unit)
      (if valid
        (CompilerEmbeddedStdlibCompressedHeaderValid raw-len (+ index 1))
        (CompilerEmbeddedStdlibCompressedHeaderInvalid)))))

(define (compiler-embedded-stdlib-lzss-decode
  [compressed : (& compressed (Array u8))]
  [compressed-start : i64]
  [raw-len : i64]) : String
  (let
    [out : (Array u8) (array.make-array u8 raw-len)]
    [compressed-index : i64 0]
    [out-index : i64 0]
    [compressed-len : i64 (- (array-length compressed) compressed-start)]
    (begin
      (while (and (< compressed-index compressed-len) (< out-index raw-len))
        (let
          [flags : i64
            (cast
              (array-ref compressed (+ compressed-start compressed-index))
              : i64)]
          [bit : i64 0]
          (begin
            (set! compressed-index (+ compressed-index 1))
            (while (and
              (< bit 8)
              (< compressed-index compressed-len)
              (< out-index raw-len))
              (begin
                (if (!= (bit-and flags (shl 1 bit)) 0)
                  (begin
                    (array-set!
                      out
                      out-index
                      (array-ref
                        compressed
                        (+ compressed-start compressed-index)))
                    (set! compressed-index (+ compressed-index 1))
                    (set! out-index (+ out-index 1)))
                  (let
                    [packed : i64
                      (bit-or
                        (shl
                          (cast
                            (array-ref
                              compressed
                              (+ compressed-start compressed-index))
                            : i64)
                          8)
                        (cast
                          (array-ref
                            compressed
                            (+ compressed-start (+ compressed-index 1)))
                          : i64))]
                    [offset : i64 (+ (shr packed 4) 1)]
                    [length : i64 (+ (bit-and packed 15) 3)]
                    [copy-index : i64 0]
                    (begin
                      (set! compressed-index (+ compressed-index 2))
                      (while (and (< copy-index length) (< out-index raw-len))
                        (begin
                          (array-set!
                            out
                            out-index
                            (array-ref out (- out-index offset)))
                          (set! out-index (+ out-index 1))
                          (set! copy-index (+ copy-index 1)))))))
                (set! bit (+ bit 1)))))))
      (if (or (!= out-index raw-len) (!= compressed-index compressed-len))
        (begin
          (string.tl_oob_abort)
          "")
        (if (= raw-len 0)
          ""
          (let
            [data : (MutPtr u8)
              (unsafe
                (array-data out))]
            (unsafe
              (string-from-bytes (ptr-cast data : (Ptr u8)) raw-len))))))))

(define (compiler-embedded-stdlib-lookup [suffix : String]) : CompilerEmbeddedStdlibSource
  (match (payload.compiler-embedded-stdlib-payload-lookup suffix)
    [(payload.CompilerEmbeddedStdlibPayloadNone)
      (CompilerEmbeddedStdlibNoSource)]
    [(payload.CompilerEmbeddedStdlibPayloadSome compressed)
      (let
        [compressed-prefix : String
          (compiler-embedded-stdlib-compressed-prefix)]
        (if (compiler-embedded-stdlib-payload-prefix?
          (& compressed)
          compressed-prefix)
          (match (compiler-embedded-stdlib-compressed-header
            (& compressed)
            (string.string-length compressed-prefix))
            [(CompilerEmbeddedStdlibCompressedHeaderValid raw-len start)
              (CompilerEmbeddedStdlibSomeSource
                (compiler-embedded-stdlib-lzss-decode
                  (& compressed)
                  start
                  raw-len))]
            [(CompilerEmbeddedStdlibCompressedHeaderInvalid)
              (begin
                (string.tl_oob_abort)
                (CompilerEmbeddedStdlibNoSource))])
          (begin
            (string.tl_oob_abort)
            (CompilerEmbeddedStdlibNoSource))))]))