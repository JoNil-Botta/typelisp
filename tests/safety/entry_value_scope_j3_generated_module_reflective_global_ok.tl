;; #9687: a global read through a reflected entry value, with a same-name module value.
(import stdlib.comptime)

(defstruct Foo
  (x i64))

(define gv : i64
  39)

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.j3)
    (import stdlib.comptime)
    (defmacro (inner [U : type]) : Expr
      (comptime.module-value-expr (type-nominal-module U) "gv"))
    (define gv : i64
      1)
    (define (call-it) : i64
      (inner ,T))))

(import (gen Foo) as g)

(define (main) : i64
  (g.call-it))