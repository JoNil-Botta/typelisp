(define (borrow-n [n : i64]) : (& n i64)
  (& n))

(define (use [n : i64]) : i64
  (begin
    (borrow-n n)
    42))

(define (main) : i64
  (use 41))