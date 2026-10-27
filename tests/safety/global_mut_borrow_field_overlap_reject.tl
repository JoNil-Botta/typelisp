(defstruct Pair
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(define (write-two! [_x : (&mut x i64)] [_y : (&mut y i64)]) : unit
  unit)

(define (main) : unit
  (write-two! (&mut state.x) (&mut state.x)))