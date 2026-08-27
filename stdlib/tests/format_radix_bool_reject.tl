(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:x}" true)
    42))
