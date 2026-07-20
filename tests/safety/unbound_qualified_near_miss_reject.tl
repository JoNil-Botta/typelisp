(import stdlib.string)

(define (main) : i64
  (if (string.eqq "left" "right")
    0
    1))