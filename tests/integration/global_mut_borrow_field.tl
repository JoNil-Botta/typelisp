(defstruct Pair
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(define (change! [p : (&mut p i64)]) : unit
  (set! (deref p) 5))

(define (main) : i64
  (change! (&mut state.x))
  state.x)