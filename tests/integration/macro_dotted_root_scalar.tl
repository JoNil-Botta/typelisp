(defstruct Pair
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(defmacro (read-y) : Expr
  'state.y)

(define (main) : i64
  (let
    [state : i64 30]
    (unless (= state 30) (return 1))
    (read-y)))