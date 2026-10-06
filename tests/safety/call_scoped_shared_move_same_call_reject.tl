;; A call that keeps no borrow past its return still checks its own arguments:
;; `x` cannot be moved into the call while another argument borrows it.
(import stdlib.string)

(defstruct Pair
  (a i64)
  (b String))

(define (take [p : (& Pair)] [q : Pair]) : i64
  (+ p.a q.a))

; Must fail: `x` is moved while the same call borrows it.
(define (main) : i64
  (let
    [x : Pair (Pair 1 (string.copy "x"))]
    (take (& x) x)))