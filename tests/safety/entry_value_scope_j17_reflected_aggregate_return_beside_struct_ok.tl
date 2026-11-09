;; #9687: a reflected entry function returning a large struct, beside a same-named module struct.
(import stdlib.comptime)

(defstruct Foo
  (x i64)
  (y i64)
  (z i64)
  (w i64))

(define (make [x : i64] [y : i64] [z : i64] [w : i64]) : Foo
  (Foo (+ x 1) y z w))

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.ag)
    (import stdlib.comptime)
    (defstruct make
      (x i64)
      (y i64)
      (z i64)
      (w i64))
    (defmacro (invoke [U : type]) : Expr
      (comptime.expr-call
        (comptime.module-value-expr (type-nominal-module U) "make")
        (comptime.expr-list-cons
          (comptime.expr-int 41)
          (comptime.expr-list-cons
            (comptime.expr-int 2)
            (comptime.expr-list-cons
              (comptime.expr-int 3)
              (comptime.expr-list-cons
                (comptime.expr-int 4)
                (comptime.expr-list-empty)))))))
    (define (call-it) : ,T
      (invoke ,T))))

(import (gen Foo) as g)

(define (main) : i64
  (let
    [v : Foo (g.call-it)]
    v.x))