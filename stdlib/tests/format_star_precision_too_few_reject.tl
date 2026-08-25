(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:.*}" (cast 3 : i64))
    42))