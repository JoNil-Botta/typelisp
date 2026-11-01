(defstruct Pair
  (x i64)
  (y i64))

(defstruct Triple
  (first i64)
  (x i64)
  (y i64))

(define state : Pair
  (Pair 1 2))

(defmacro (read-y) : Expr
  'state.y)

(define (main) : i64
  (let
    [state : Triple (Triple 10 20 30)]
    (unless (= state.y 30) (return 1))
    (read-y)))