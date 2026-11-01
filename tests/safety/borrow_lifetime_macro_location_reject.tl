(defstruct Pair
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [state : Pair (Pair 1 2)]
    (begin
      (when
        true
        (let
          [r : (& state i64) (& other state.x)]
          unit))
      0)))