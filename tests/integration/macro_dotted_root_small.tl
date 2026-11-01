(defstruct Pair
  (x i64)
  (y i64))

(defstruct Cell
  (x i64))

(define state : Pair
  (Pair 1 2))

(defmacro (read-y) : Expr
  'state.y)

(define (main) : i64
  (let
    [state : Cell (Cell 30)]
    (unless (= state.x 30) (return 1))
    (read-y)))