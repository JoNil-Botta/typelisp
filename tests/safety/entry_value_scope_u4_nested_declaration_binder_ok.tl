;; #9687: a nested macro binds the spelling of a settled declaration reference.
(import stdlib.comptime)

(defstruct Own
  (v i64))

(define same : i64
  42)

(defmacro (inner [e : Expr]) : Expr
  (match e
    [(comptime.Expr.Var i)
      (comptime.expr-let-scope i (comptime.expr-int 7) (comptime.expr-var i))]
    [_ (comptime.comptime-error "no")]))

(defmacro (m [X : type]) : Expr
  `(inner ,(comptime.module-value-expr (type-nominal-module X) "same")))

(define (main) : i64
  (cast (m Own) : i64))