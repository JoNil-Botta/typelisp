(define state : i64
  1)
(define copied : i64
  (deref (& other state)))

(define (main) : i64
  copied)