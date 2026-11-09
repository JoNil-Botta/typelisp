;; #9687: an inspected definition-site reference ignores a same-named generated declaration.
(import stdlib.comptime)

(define helper : i64
  42)

(defmacro (relay [e : Expr]) : Expr
  (match e
    [(comptime.Expr.Var n) (comptime.module-hook "" n)]
    [_ (comptime.expr-int 99)]))

(defmacro (m) : Expr
  `(relay helper))

(defmacro (gen) : Module
  `(begin
    (module generated.inspected)
    (define helper : i64
      1)
    (define (f) : i64
      (m))))

(import (gen) as g)

(define (main) : i64
  (g.f))
