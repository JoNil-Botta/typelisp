(define (make-ref-tuple [n : i64]) : (Tuple (& n i64) i64)
  (tuple (& n) 7))

(define (use [n : i64]) : i64
  (begin
    (make-ref-tuple n)
    42))

(define (main) : i64
  (use 41))