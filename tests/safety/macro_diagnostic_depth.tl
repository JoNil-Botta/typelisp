(defmacro (again) : Expr
  `(again))

(define (main) : i64
  (again))