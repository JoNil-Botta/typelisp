(defstruct Pair
  (left i64)
  (right i64))

(defmacro (bad-pair [value : Expr]) : Expr
  `(match ,value
    [(fields missing) missing]))

(define (main [pair : Pair]) : i64
  (bad-pair pair))