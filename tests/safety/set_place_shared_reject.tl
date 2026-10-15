;; Place evaluation order does not grant mutation through a shared borrow.
(define (write [a : (& a (Array i64 1))]) : unit
  (set! (array-ref a 0) 7))

(define (main) : i64
  0)