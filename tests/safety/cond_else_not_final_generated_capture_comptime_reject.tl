(import stdlib.comptime)

(defmacro (capture-cond [n : Expr]) : Expr
  (comptime.expr-let-scope
    "cond allows [else ...] only as the final arm"
    n
    `(cond [else 0] [true 1])))

(define (main) : i64
  (comptime (capture-cond 7)))