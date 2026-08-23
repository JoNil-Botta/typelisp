(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:9223372036854775808}" "value")
    42))