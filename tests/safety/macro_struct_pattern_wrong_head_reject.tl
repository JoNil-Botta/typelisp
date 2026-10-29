(defstruct Pair
  (left i64)
  (right i64))

(defstruct Other
  (left i64)
  (right i64))

(defmacro (bad-pair [value : Expr]) : Expr
  `(match ,value
    [(Other a b) (+ a b)]))

(define (main [pair : (& pair Pair)]) : i64
  (bad-pair pair))