;; Payload-free test placeholder. Inline-test harnesses use explicit source
;; roots instead of recompressing the compiler payload for every file.
(defenum CompilerEmbeddedStdlibPayload
  (CompilerEmbeddedStdlibPayloadNone)
  (CompilerEmbeddedStdlibPayloadSome (__tl_dyn-array u8) i64))

(define (compiler-embedded-stdlib-payload-container) : (__tl_dyn-array u8)
  (__tl_make-array u8 0))

(define (compiler-embedded-stdlib-payload-lookup [_suffix : String]) : CompilerEmbeddedStdlibPayload
  (CompilerEmbeddedStdlibPayloadNone))