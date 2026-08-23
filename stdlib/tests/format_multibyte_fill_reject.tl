(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{:é<5}" "value")
    42))