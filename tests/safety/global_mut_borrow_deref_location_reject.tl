(defstruct Pair
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(define (main) : i64
  (deref (&mut state.x)))