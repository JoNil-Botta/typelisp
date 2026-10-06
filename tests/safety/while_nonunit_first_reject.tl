;; Direct while body forms must each be unit-valued, even in an inactive loop.
(define (value) : i64
  1)

(define (main) : i64
  (while false
    (value)
    unit)
  0)