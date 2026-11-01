(defstruct Pair
  (x i64)
  (y i64))

(defstruct Outer
  (inner Pair)
  (tail i64))

(define outer : Outer
  (Outer (Pair 5 6) 7))

(defmacro (read-nested) : Expr
  'outer.inner.y)

(define (main) : i64
  (let
    [outer : Pair (Pair 20 30)]
    (unless (= outer.y 30) (return 1))
    (read-nested)))