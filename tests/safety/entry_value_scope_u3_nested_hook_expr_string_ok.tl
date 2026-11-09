;; #9687: a nested macro reads a settled declaration reference as text.
(import stdlib.comptime)

(defstruct Own
  (v i64))

(define same : i64
  42)

(defmacro (inner [e : Expr]) : Expr
  (match e
    [(comptime.Expr.Var i)
      (comptime.expr-call
        (comptime.expr-var "__tl_string_length")
        (comptime.expr-list-cons
          (comptime.expr-string i)
          (comptime.expr-list-empty)))]
    [_ (comptime.comptime-error "no")]))

(defmacro (m [X : type]) : Expr
  `(inner ,(comptime.module-hook (type-nominal-module X) "same")))

(define (main) : i64
  (+ 38 (cast (m Own) : i64)))