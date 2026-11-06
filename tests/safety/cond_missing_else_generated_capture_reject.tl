(import stdlib.comptime)

(defmacro (capture-cond [n : Expr]) : Expr
  (comptime.expr-let-scope
    "cond requires a final [else ...] arm"
    n
    `(cond [true 1])))

(define (f [n : i64]) : i64
  (capture-cond n))

(define (main) : i64
  (f 7))