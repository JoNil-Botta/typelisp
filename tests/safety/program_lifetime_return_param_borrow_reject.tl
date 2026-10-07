;; A borrow of a parameter does not live as long as `program`.
(define (leak [n : i64]) : (& program i64)
  (& n))

(define (main) : i64
  (deref (leak 42)))