;; Calling an unsafe C function pointer requires an `unsafe` context.
(extern raw-scorer (:symbol "tl_mir_raw_scorer") : (CFunc
  unsafe-non-null
  (-> i64 i64)))

(define (main) : i64
  (raw-scorer 42))