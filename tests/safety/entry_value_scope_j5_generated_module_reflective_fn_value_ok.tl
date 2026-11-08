;; #9687: a function value through a reflected entry value, with a same-name module function.
(import stdlib.comptime)

(defstruct Foo
  (x i64))

(define (same) : i64
  41)

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.j5)
    (import stdlib.comptime)
    (defmacro (inner [U : type]) : Expr
      (comptime.module-value-expr (type-nominal-module U) "same"))
    (define (same) : i64
      1)
    (define (call-it) : i64
      (let
        [f (inner ,T)]
        (f)))))

(import (gen Foo) as g)

(define (main) : i64
  (g.call-it))