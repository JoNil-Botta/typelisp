(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{0:2$}" "value" (cast 4 : i64))
    42))