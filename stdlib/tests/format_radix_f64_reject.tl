(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:X}" (cast 1.5 : f64))
    42))
