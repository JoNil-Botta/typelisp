(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{0:1$}" "value" true)
    42))