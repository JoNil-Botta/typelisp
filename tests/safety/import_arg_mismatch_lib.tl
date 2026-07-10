(define (takes-i64 [x : i64]) : i64
  x)

(define (bad-imported-call) : i64
  (takes-i64 true))