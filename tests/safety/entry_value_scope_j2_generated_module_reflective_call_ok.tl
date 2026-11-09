;; #9687: a call through a reflected entry value from a generated module.
(import stdlib.comptime)

(defstruct Foo
  (x i64))

(define (same) : i64
  38)

(define gv : i64
  2)

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.j2)
    (import stdlib.comptime)
    (defmacro (inner [U : type]) : Expr
      (comptime.expr-call
        (comptime.module-value-expr (type-nominal-module U) "same")
        (comptime.expr-list-empty)))
    (define (same) : i64
      1)
    (define (call-it) : i64
      (inner ,T))))

(import (gen Foo) as g)

(define (main) : i64
  (g.call-it))