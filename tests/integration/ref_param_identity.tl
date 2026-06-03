(define (id [r : (& n i64)]) : (& n i64)
  r)

(define (use [n : i64]) : i64
  (begin
    (id (& n))
    42))

(define (main) : i64
  (use 41))