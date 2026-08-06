;; compiler_embedded_stdlib.tl - Exact-source compressed stdlib fallback.
(cfg
  (any stage0-seed-bootstrap test)
  (import compiler_embedded_stdlib_payload_seed as payload))
(cfg
  (not (any stage0-seed-bootstrap test))
  (import compiler_embedded_stdlib_payload as payload))
(import compiler_lzss as lzss)
(import stdlib.string)

(defenum CompilerEmbeddedStdlibSource
  (CompilerEmbeddedStdlibNoSource)
  (CompilerEmbeddedStdlibSomeSource String))

;; Individual embedded source modules are currently below 0.2 MiB. The 16 MiB
;; ceiling leaves ample growth while rejecting corrupt length headers before
;; they can request an unbounded allocation.
(define (compiler-embedded-stdlib-source-limit) : i64
  16777216)

(define (compiler-embedded-stdlib-bytes->string [bytes : (__tl_dyn-array u8)]) : String
  (if (= (array-length bytes) 0)
    ""
    (let
      [data : (MutPtr u8)
        (unsafe
          (array-data bytes))]
      (unsafe
        (string-from-bytes (ptr-cast data : (Ptr u8)) (array-length bytes))))))

(define (compiler-embedded-stdlib-lookup [suffix : String]) : CompilerEmbeddedStdlibSource
  (match (payload.compiler-embedded-stdlib-payload-lookup suffix)
    [(payload.CompilerEmbeddedStdlibPayloadNone)
      (CompilerEmbeddedStdlibNoSource)]
    [(payload.CompilerEmbeddedStdlibPayloadSome compressed)
      (match (lzss.compiler-lzss-decode
        (& compressed)
        (compiler-embedded-stdlib-source-limit))
        [(lzss.CompilerLzssBytes.Ok bytes)
          (CompilerEmbeddedStdlibSomeSource
            (compiler-embedded-stdlib-bytes->string bytes))]
        [(lzss.CompilerLzssBytes.Err _)
          (begin
            (string.tl_oob_abort)
            (CompilerEmbeddedStdlibNoSource))])]))