(import stdlib.comptime)

(defmacro (capture-cond [n : Expr]) : Expr
  (comptime.expr-let-scope
    "cond requires a final [else ...] arm"
    n
    `(cond [true 1])))

(define (main) : i64
  (comptime (capture-cond 7)))