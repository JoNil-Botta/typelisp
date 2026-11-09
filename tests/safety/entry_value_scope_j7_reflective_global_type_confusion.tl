;; #9687: a reflected entry value with a same-name module value of another type.
(import stdlib.comptime)

(defstruct Foo
  (x i64))

(define gv : i64
  39)

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.j7)
    (import stdlib.comptime)
    (defmacro (inner [U : type]) : Expr
      (comptime.module-value-expr (type-nominal-module U) "gv"))
    (define gv : bool
      true)
    (define (call-it) : i64
      (+ 0 (inner ,T)))))

(import (gen Foo) as g)

(define (main) : i64
  (g.call-it))