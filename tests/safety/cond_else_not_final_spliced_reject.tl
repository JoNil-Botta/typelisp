(defmacro (identity [value : Expr]) : Expr
  value)

(define (main) : i64
  (identity (cond [else 0] [true 1])))