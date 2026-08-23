(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{0:1$}" "value" (cast -1 : i64))
    42))