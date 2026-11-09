;; #9687: a literal "" owner in a generated module, seen from an imported module.
(import stdlib.comptime)

(define (helper) : i64
  35)

(defmacro (gen) : Module
  `(begin
    (module generated.scope.literal)
    (import stdlib.comptime)
    (defmacro (inner) : Expr
      (comptime.expr-call
        (comptime.module-value-expr "" "helper")
        (comptime.expr-list-empty)))
    (define (call-it) : i64
      (inner))))

(import (gen) as g)

(define (main) : i64
  (g.call-it))