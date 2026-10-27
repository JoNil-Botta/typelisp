(defstruct Pair
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(define (read-after [p : (& p i64)] [n : i64]) : i64
  (+ (deref p) n))

(define (main) : i64
  (read-after
    (& state.x)
    (begin
      (set! state.x 5)
      0)))