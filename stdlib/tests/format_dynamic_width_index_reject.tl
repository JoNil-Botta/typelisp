(import stdlib.format)

(define (main) : i64
  (format.format "{0:2$}" "value" (cast 4 : i64))
  42)