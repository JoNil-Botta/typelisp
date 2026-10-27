(defstruct Pair
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(define (main) : i64
  (let
    [r : (&mut r i64) (&mut state.x)]
    (set! (deref r) 5))
  state.x)