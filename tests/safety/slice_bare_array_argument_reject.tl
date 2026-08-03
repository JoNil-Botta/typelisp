;; Slice formals do not trigger the ordinary immutable-ref auto-borrow.
(define (read [s : (& s (Slice i64))]) : i64
  (array-ref s 0))

(define (main) : i64
  (let
    [a : (Array i64 1) (array 7)]
    (read a)))