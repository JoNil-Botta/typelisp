(import stdlib.comptime)

(defmacro (capture-cond [n : Expr]) : Expr
  (comptime.expr-let-scope
    "cond allows [else ...] only as the final arm"
    n
    `(cond [else 0] [true 1])))

(define (f [n : i64]) : i64
  (capture-cond n))

(define (main) : i64
  (f 7))