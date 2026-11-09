;; #9687: a reflected entry function returning a large struct, beside a same-name module function.
(import stdlib.comptime)

(defstruct Foo
  (x i64)
  (y i64)
  (z i64)
  (w i64))

(define (make) : Foo
  (Foo 42 2 3 4))

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.ag)
    (import stdlib.comptime)
    (defmacro (invoke [U : type]) : Expr
      (comptime.expr-call
        (comptime.module-value-expr (type-nominal-module U) "make")
        (comptime.expr-list-empty)))
    (define (make) : ,T
      (init : ,T))
    (define (call-it) : ,T
      (invoke ,T))))

(import (gen Foo) as g)

(define (main) : i64
  (let
    [v : Foo (g.call-it)]
    v.x))