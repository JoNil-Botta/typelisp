(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:?}" (tuple 1 true))
    42))