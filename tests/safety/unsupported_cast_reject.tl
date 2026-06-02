;: SPEC safe-code contract: non-numeric casts are statically rejected.
(define (main) : i64
  (cast true : i64))