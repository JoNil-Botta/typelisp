(defstruct Pair
  (left i64)
  (right i64))

(defmacro (bad-pair [value : Expr]) : Expr
  `(match ,value
    [(Pair a b) (+ a b)]
    [_ 0]))

(define (main [pair : Pair]) : i64
  (bad-pair pair))