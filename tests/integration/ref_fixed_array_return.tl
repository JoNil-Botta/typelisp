(define (make-ref-array [n : i64]) : (Array (& n i64) 1)
  (array (& n)))

(define (use [n : i64]) : i64
  (begin
    (make-ref-array n)
    42))

(define (main) : i64
  (use 41))