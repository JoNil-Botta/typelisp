(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{}" (cast 7 : i64) (cast 8 : i64))
    42))
