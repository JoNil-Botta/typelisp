(defstruct Pair
  (a i64)
  (b i64))

(define (probe) : i64
  (let
    [p : Pair (Pair 1 (return 0))]
    [q : i64 true]
    (+ p.a q)))

(define (main) : i64
  0)