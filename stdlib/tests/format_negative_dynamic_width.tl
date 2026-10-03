(import stdlib.format)

(define (main) : i64
  (format.format "{0:1$}" "value" (cast -1 : i64))
  42)