(import stdlib.format)

(define (main) : i64
  (begin
    (format.format-debug-checked-length-add 9223372036854775807 4)
    42))