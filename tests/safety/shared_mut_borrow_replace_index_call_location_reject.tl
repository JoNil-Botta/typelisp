(defstruct Pair
  (x i64)
  (y i64))

(define (pick [v : (&mut i64)]) : i64
  (deref v))

(define (main) : i64
  (let
    [state : Pair (Pair 1 2)]
    [shared : (& state Pair) (& state)]
    [items : (Array i64 2) (array 1 2)]
    (replace! (array-ref items (pick (&mut shared.x))) 5)))