(import stdlib.format)

(define (main) : i64
  (format.format "{0:.2$}" (cast 7 : i64) (cast 3 : i64))
  42)