;; #9687: a text-built name in a generated module, seen from an imported module.
(import stdlib.comptime)

(define (entry-fn) : i64
  44)

(defmacro (gen) : Module
  (let
    [call : comptime.Expr
      (comptime.expr-call
        (comptime.expr-var "entry-fn")
        (comptime.expr-list-empty))]
    `(begin
      (module generated.scope.textual)
      (define (call-it) : i64
        ,call))))

(import (gen) as g)

(define (main) : i64
  (g.call-it))