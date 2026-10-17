(defstruct Pair
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [_p : Pair (Pair 1 2)]
    (set! _p.a (return 42))
    (set! _p.b true)
    0))