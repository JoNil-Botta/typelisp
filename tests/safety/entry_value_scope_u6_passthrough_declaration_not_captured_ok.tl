;; #9687: a declaration reference passed through a nested binder of its spelling is not captured.
(import stdlib.comptime)

(define hits : i64
  0)

(define (close-tok [_v : i64]) : unit
  (set! hits (+ hits 1)))

(defstruct Own
  (:cleanup clean)
  (v i64 (:cleanup close-tok)))

(define same : i64
  7)

(defmacro (inner [e : Expr]) : Expr
  (match e
    [(comptime.Expr.Var i) (comptime.expr-let-scope i (comptime.expr-int 42) e)]
    [_ (comptime.comptime-error "no")]))

(defmacro (m [X : type]) : Expr
  `(inner ,(comptime.module-value-expr (type-nominal-module X) "same")))

(define (main) : i64
  (cast (m Own) : i64))