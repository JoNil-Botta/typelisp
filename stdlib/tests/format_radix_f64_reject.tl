(import stdlib.format)

(define (main) : i64
  (format.format "{:X}" (cast 1.5 : f64))
  42)