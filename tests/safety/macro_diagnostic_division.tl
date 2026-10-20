(defmacro (bad) : Expr
  (expr-int (/ 1 0)))

(define (main) : i64
  (bad))