(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:.3}" (cast 1.5 : f64))
    42))