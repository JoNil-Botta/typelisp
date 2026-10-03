(import stdlib.format)

(define (main) : i64
  (format.format "{:9223372036854775808}" "value")
  42)