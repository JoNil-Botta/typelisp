(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:.3}" "value")
    42))