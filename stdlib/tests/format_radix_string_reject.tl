(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:o}" "value")
    42))