(defstruct Pair
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [state : Pair (Pair 1 2)]
    [shared : (& state Pair) (& state)]
    (begin
      (when true (set! (deref (&mut shared.x)) 5))
      0)))