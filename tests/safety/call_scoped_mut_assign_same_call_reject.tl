;; A call that keeps no borrow past its return still checks its own arguments:
;; a later argument cannot assign to a place an earlier one borrows mutably.
(import stdlib.string)

(defstruct Pair
  (a i64)
  (b String))

(define (add! [p : (&mut Pair)] [n : i64]) : i64
  (+ p.a n))

; Must fail: `x.a` is assigned while the same call mutably borrows `x`.
(define (main) : i64
  (let
    [x : Pair (Pair 1 (string.copy "x"))]
    (add!
      (&mut x)
      (begin
        (set! x.a 5)
        1))))