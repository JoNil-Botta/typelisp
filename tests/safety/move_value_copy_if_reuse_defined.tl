(defstruct Pair
  (a i64)
  (b i64))

(define (total [p : Pair]) : i64
  (+ p.a p.b))

(define (main) : i64
  (let
    [x : Pair (Pair 20 1)]
    [z : Pair (Pair 3 4)]
    [first : i64
      (total
        (if true
          x
          z))]
    (+ first (total x))))