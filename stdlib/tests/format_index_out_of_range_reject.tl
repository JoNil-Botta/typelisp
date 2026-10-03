(import stdlib.format)

(define (main) : i64
  (format.format "{2}" (cast 7 : i64) (cast 8 : i64))
  42)