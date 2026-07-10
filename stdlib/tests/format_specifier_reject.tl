(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:>3}" (cast 7 : i64))
    42))