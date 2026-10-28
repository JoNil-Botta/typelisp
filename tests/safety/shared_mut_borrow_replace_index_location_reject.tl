(defstruct Pair
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [state : Pair (Pair 1 2)]
    [shared : (& state Pair) (& state)]
    [items : (Array i64 2) (array 1 2)]
    (replace! (array-ref items (deref (&mut shared.x))) 5)))