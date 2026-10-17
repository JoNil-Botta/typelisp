;: A field of a by-value aggregate parameter is the call's own storage too.
(defstruct Pair
  (left i64)
  (right i64))

(define (borrow-left [p : Pair]) : (& p i64)
  (& p.left))

(define (main) : i64
  (deref (borrow-left (Pair 42 1))))