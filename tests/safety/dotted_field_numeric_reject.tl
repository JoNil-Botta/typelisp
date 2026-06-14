(defstruct Pair
  (x i64))

(define (main) : i64
  (let
    [p : Pair (Pair 1)]
    p.0))