;; #9687: a callable entry global called through reflection from a generated module.
(import stdlib.comptime)

(defstruct Foo
  (x i64))

(define (right) : i64
  42)

(define thunk : (-> i64)
  right)

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.cell)
    (import stdlib.comptime)
    (defmacro (invoke [U : type]) : Expr
      (comptime.expr-call
        (comptime.module-value-expr (type-nominal-module U) "thunk")
        (comptime.expr-list-empty)))
    (define (call-it) : i64
      (invoke ,T))))

(import (gen Foo) as g)

(define (main) : i64
  (g.call-it))