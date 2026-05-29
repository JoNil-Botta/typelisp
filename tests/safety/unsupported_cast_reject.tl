;;; SPEC safe-code contract: unsupported casts are statically rejected.
(define (main) : i64
  (cast 3.5 : i64))