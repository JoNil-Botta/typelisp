(import stdlib.comptime)

(defmacro (shadow-error [n : Expr]) : Expr
  (comptime.expr-let-scope "comptime.comptime-error" n `(cond [true 1])))

(define (f [n : i64]) : i64
  (shadow-error n))

(define (main) : i64
  (f 7))