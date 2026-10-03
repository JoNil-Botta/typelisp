;; compiler_embedded_stdlib.tl - Exact-source compressed stdlib fallback.
(cfg test (import compiler_embedded_stdlib_payload_seed as payload))
(cfg (not test) (import compiler_embedded_stdlib_payload as payload))
(import compiler_lzss as lzss)
(import stdlib.string)

(defenum CompilerEmbeddedStdlibSource
  (CompilerEmbeddedStdlibNoSource)
  (CompilerEmbeddedStdlibSomeSource String))

;; The 16 MiB ceiling is far above any individual embedded source module while
;; rejecting corrupt length headers before they can request an unbounded
;; allocation.
(define (compiler-embedded-stdlib-source-limit) : i64
  16777216)

(define (compiler-embedded-stdlib-bytes->string [bytes : (__tl_dyn-array u8)]) : String
  (if (= (array-length bytes) 0)
    ""
    (let
      [data : (MutPtr u8)
        (unsafe
          (__tl_array-data bytes))]
      (unsafe
        (string-from-bytes (ptr-cast data : (Ptr u8)) (array-length bytes))))))

(define (compiler-embedded-stdlib-lookup [suffix : String]) : CompilerEmbeddedStdlibSource
  (match (payload.compiler-embedded-stdlib-payload-lookup suffix)
    [(CompilerEmbeddedStdlibPayloadNone) (CompilerEmbeddedStdlibNoSource)]
    [(CompilerEmbeddedStdlibPayloadSome compressed)
      (match (lzss.compiler-lzss-decode
        (& compressed)
        (compiler-embedded-stdlib-source-limit))
        [(Ok bytes)
          (CompilerEmbeddedStdlibSomeSource
            (compiler-embedded-stdlib-bytes->string bytes))]
        [(Err _)
          (begin
            (string.tl_oob_abort)
            (CompilerEmbeddedStdlibNoSource))])]))