(define (take-mut [n : (&mut n i64)]) : i64
  1)

(define (main [n : i64]) : i64
  (take-mut n))