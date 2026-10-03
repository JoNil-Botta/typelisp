(import stdlib.format)

(define (main) : i64
  (format.format "{:.}" (cast 7 : i64))
  42)