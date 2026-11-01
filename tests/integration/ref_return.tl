;: A reference returned through a reference parameter keeps the caller's
;: lifetime; a by-value parameter is borrowed only within its call.
(define (borrow-n [n : (& n i64)]) : (& n i64)
  n)

(define (read-own [n : i64]) : i64
  (deref (borrow-n (& n))))

(define (use [n : i64]) : i64
  (+ (deref (borrow-n (& n))) (read-own 1)))

(define (main) : i64
  (use 41))