(defstruct Pair
  (left i64)
  (right i64))

(defmacro (bad-pair [value : Expr]) : Expr
  `(match ,value
    [(Pair a) a]))

(define (main [pair : Pair]) : i64
  (bad-pair pair))