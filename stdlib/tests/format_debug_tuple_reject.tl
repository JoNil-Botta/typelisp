(import stdlib.format)

(define (main) : i64
  (format.format "{:?}" (tuple 1 true))
  42)