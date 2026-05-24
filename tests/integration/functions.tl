(define (double [x : i64]) : i64
  (+ x x))

(define (add3 [a : i64] [b : i64] [c : i64]) : i64
  (+ (+ a b) c))

(define (main) : i64
  (add3 (double 10) 5 7))