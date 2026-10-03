(import stdlib.format)

(define (main) : i64
  (format.format "{0:.1$}" (cast 7 : i64) (cast -1 : i64))
  42)