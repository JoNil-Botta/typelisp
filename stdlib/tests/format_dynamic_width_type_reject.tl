(import stdlib.format)

(define (main) : i64
  (format.format "{0:1$}" "value" true)
  42)