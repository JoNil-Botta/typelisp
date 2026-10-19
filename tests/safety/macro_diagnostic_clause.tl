(defmacro (take [_arm : ExprClause]) : i64
  (expr-int 0))

(define (main) : i64
  (take 42))