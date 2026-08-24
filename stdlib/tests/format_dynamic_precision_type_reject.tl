(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{0:.1$}" (cast 7 : i64) true)
    42))