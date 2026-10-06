;; A call that keeps no borrow past its return still checks its own arguments:
;; a field cannot be moved out of a variable the same call borrows mutably.
(import stdlib.string)

(defstruct Pair
  (a i64)
  (b String))

(define (keep! [p : (&mut Pair)] [s : String]) : i64
  p.a)

; Must fail: `x.b` is moved while the same call mutably borrows `x`.
(define (main) : i64
  (let
    [x : Pair (Pair 1 (string.copy "x"))]
    (keep! (&mut x) x.b)))