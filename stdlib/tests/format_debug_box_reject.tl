(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:?}" (box 1))
    42))