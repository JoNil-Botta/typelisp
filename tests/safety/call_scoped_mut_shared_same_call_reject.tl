;; A call that keeps no borrow past its return still checks its own arguments:
;; `x` cannot be borrowed mutably and shared by the same call, even in a body
;; with no other borrow.
(import stdlib.string)

(defstruct Pair
  (a i64)
  (b String))

(define (mix! [p : (&mut Pair)] [q : (& Pair)]) : i64
  (+ p.a q.a))

; Must fail: `x` is mutably borrowed while the same call shares it.
(define (main) : i64
  (let
    [x : Pair (Pair 1 (string.copy "x"))]
    (mix! (&mut x) (& x))))