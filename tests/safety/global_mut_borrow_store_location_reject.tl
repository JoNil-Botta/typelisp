(defstruct Pair
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(define (main) : i64
  (set! (deref (&mut state.x)) 5)
  state.x)