(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:b}" 'x')
    42))