;; Payload-free bootstrap/test placeholder. The published compiler cannot
;; expand the new build input in stage1, and inline-test harnesses use explicit
;; source roots instead of recompressing the compiler payload for every file.
(defenum CompilerEmbeddedStdlibPayload
  (CompilerEmbeddedStdlibPayloadNone)
  (CompilerEmbeddedStdlibPayloadSome (__tl_dyn-array u8)))

(define (compiler-embedded-stdlib-payload-lookup [_suffix : String]) : CompilerEmbeddedStdlibPayload
  (CompilerEmbeddedStdlibPayloadNone))