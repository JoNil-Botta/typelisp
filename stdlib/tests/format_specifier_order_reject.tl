(import stdlib.format)

(define (main) : i64
  (format.format "{:5+}" (cast 7 : i64))
  42)