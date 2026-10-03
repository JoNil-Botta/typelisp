(import stdlib.format)

(define (main) : i64
  (format.format "{12x}" (cast 7 : i64))
  42)