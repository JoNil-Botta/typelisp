(import stdlib.format)

(define (main) : i64
  (begin
    (format.formatter-write-string-at! 1 "x")
    0))