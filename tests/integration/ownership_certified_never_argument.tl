(import stdlib.runtime)

(define (sum [left : i64] [right : i64]) : i64
  (+ left right))

(define (main) : i64
  (sum (runtime.os-exit 42) (runtime.os-exit 1)))