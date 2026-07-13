;; compiler_embedded_stdlib.tl - Exact-source compressed stdlib fallback.
(import compiler_embedded_stdlib_payload as payload)
(import stdlib.array)
(import stdlib.string)

(defenum CompilerEmbeddedStdlibSource
  (CompilerEmbeddedStdlibNoSource)
  (CompilerEmbeddedStdlibSomeSource String))

(define (compiler-embedded-stdlib-base64-value [c : char]) : i64
  (cond
    [(and (>= c 'A') (<= c 'Z')) (- (cast c : i64) (cast 'A' : i64))]
    [(and (>= c 'a') (<= c 'z')) (+ 26 (- (cast c : i64) (cast 'a' : i64)))]
    [(and (>= c '0') (<= c '9')) (+ 52 (- (cast c : i64) (cast '0' : i64)))]
    [(= c '+') 62]
    [(= c '/') 63]
    [else 0]))

(define (compiler-embedded-stdlib-base64-decode-chunk!
  [encoded : String]
  [out : (&mut out (Array u8))]
  [compressed-len : i64]
  [out-index : i64]) : i64
  (let
    [encoded-index : i64 0]
    [decoded-index : i64 out-index]
    [encoded-len : i64 (string.string-length encoded)]
    (begin
      (while (< encoded-index encoded-len)
        (let
          [a : i64
            (compiler-embedded-stdlib-base64-value
              (string.string-ref encoded encoded-index))]
          [b : i64
            (compiler-embedded-stdlib-base64-value
              (string.string-ref encoded (+ encoded-index 1)))]
          [c : i64
            (compiler-embedded-stdlib-base64-value
              (string.string-ref encoded (+ encoded-index 2)))]
          [d : i64
            (compiler-embedded-stdlib-base64-value
              (string.string-ref encoded (+ encoded-index 3)))]
          (begin
            (when
              (< decoded-index compressed-len)
              (begin
                (array-set!
                  out
                  decoded-index
                  (cast (bit-or (shl a 2) (shr b 4)) : u8))
                (set! decoded-index (+ decoded-index 1))))
            (when
              (< decoded-index compressed-len)
              (begin
                (array-set!
                  out
                  decoded-index
                  (cast (bit-or (shl (bit-and b 15) 4) (shr c 2)) : u8))
                (set! decoded-index (+ decoded-index 1))))
            (when
              (< decoded-index compressed-len)
              (begin
                (array-set!
                  out
                  decoded-index
                  (cast (bit-or (shl (bit-and c 3) 6) d) : u8))
                (set! decoded-index (+ decoded-index 1))))
            (set! encoded-index (+ encoded-index 4)))))
      decoded-index)))

(define (compiler-embedded-stdlib-base64-decode-chunks!
  [chunks : payload.CompilerEmbeddedStdlibPayloadChunks]
  [out : (&mut out (Array u8))]
  [compressed-len : i64]
  [out-index : i64]) : i64
  (match chunks
    [(payload.CompilerEmbeddedStdlibPayloadChunkNil) out-index]
    [(payload.CompilerEmbeddedStdlibPayloadChunkCons encoded rest)
      (compiler-embedded-stdlib-base64-decode-chunks!
        (box-get rest)
        out
        compressed-len
        (compiler-embedded-stdlib-base64-decode-chunk!
          encoded
          out
          compressed-len
          out-index))]))

(define (compiler-embedded-stdlib-lzss-decode
  [compressed : (& compressed (Array u8))]
  [raw-len : i64]) : String
  (let
    [out : (Array u8) (array.make-array u8 raw-len)]
    [compressed-index : i64 0]
    [out-index : i64 0]
    [compressed-len : i64 (array-length compressed)]
    (begin
      (while (and (< compressed-index compressed-len) (< out-index raw-len))
        (let
          [flags : i64 (cast (array-ref compressed compressed-index) : i64)]
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
                      (array-ref compressed compressed-index))
                    (set! compressed-index (+ compressed-index 1))
                    (set! out-index (+ out-index 1)))
                  (let
                    [packed : i64
                      (bit-or
                        (shl
                          (cast (array-ref compressed compressed-index) : i64)
                          8)
                        (cast
                          (array-ref compressed (+ compressed-index 1))
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

(define (compiler-embedded-stdlib-decode
  [raw-len : i64]
  [compressed-len : i64]
  [chunks : payload.CompilerEmbeddedStdlibPayloadChunks]) : String
  (let
    [compressed : (Array u8) (array.make-array u8 compressed-len)]
    [decoded-len : i64
      (compiler-embedded-stdlib-base64-decode-chunks!
        chunks
        (&mut compressed)
        compressed-len
        0)]
    (if (= decoded-len compressed-len)
      (compiler-embedded-stdlib-lzss-decode (& compressed) raw-len)
      (begin
        (string.tl_oob_abort)
        ""))))

(define (compiler-embedded-stdlib-lookup [suffix : String]) : CompilerEmbeddedStdlibSource
  (match (payload.compiler-embedded-stdlib-payload-lookup suffix)
    [(payload.CompilerEmbeddedStdlibPayloadNone)
      (CompilerEmbeddedStdlibNoSource)]
    [(payload.CompilerEmbeddedStdlibPayloadSome raw-len compressed-len chunks)
      (CompilerEmbeddedStdlibSomeSource
        (compiler-embedded-stdlib-decode raw-len compressed-len chunks))]))