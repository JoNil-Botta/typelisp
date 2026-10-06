;; A call that keeps no borrow past its return still checks its own arguments:
;; a nested call in a later argument cannot mutably borrow what an earlier
;; argument shares.
(import stdlib.string)

(defstruct Pair
  (a i64)
  (b String))

(define (total [p : (& Pair)] [n : i64]) : i64
  (+ p.a n))

(define (bump! [p : (&mut Pair)]) : i64
  (set! p.a (+ p.a 1))
  p.a)

; Must fail: the nested call mutably borrows `x` while the outer call shares it.
(define (main) : i64
  (let
    [x : Pair (Pair 1 (string.copy "x"))]
    (total (& x) (bump! (&mut x)))))