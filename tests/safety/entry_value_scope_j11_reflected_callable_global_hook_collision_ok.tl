;; #9687: a callable entry global called through module-hook beside a same-name module function.
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
        (comptime.module-hook (type-nominal-module U) "thunk")
        (comptime.expr-list-empty)))
    (define (thunk) : i64
      3)
    (define (call-it) : i64
      (invoke ,T))))

(import (gen Foo) as g)

(define (main) : i64
  (g.call-it))