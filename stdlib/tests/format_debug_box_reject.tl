(import stdlib.format)

(define (main) : i64
  (format.format "{:?}" (box 1))
  42)