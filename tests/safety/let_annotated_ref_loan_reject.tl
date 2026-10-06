;; The move and borrow checks read an annotated let binding's type from body
;; typing. A reference binding keeps its loan: `x` cannot change while `r`
;; still reads it.
(defstruct Pair
  (a i64)
  (b i64))

; Must fail: `x.a` is assigned while `r` still borrows `x`.
(define (main) : i64
  (let
    [x : Pair (Pair 1 2)]
    [r : (& x Pair) (& x)]
    (set! x.a 5)
    r.a))