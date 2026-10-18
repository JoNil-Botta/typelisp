(defstruct Pair
  (a i64))

(define (main) : i64
  (let
    [_p : Pair (Pair 1)]
    (set! _p.a (return true))
    0))