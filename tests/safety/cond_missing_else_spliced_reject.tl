(defmacro (identity [value : Expr]) : Expr
  value)

(define (main) : i64
  (identity (cond [true 0])))