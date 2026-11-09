;; #9687: a reflected entry value beside a same-name local, seen from an imported module.
(import stdlib.comptime)

(defstruct Foo
  (x i64))

(define (hook-foo) : i64
  36)

(defmacro (call-hook [T : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module T) "hook-foo")
    (comptime.expr-list-empty)))

(define (main) : i64
  (let
    [hook-foo : i64 1]
    (+ (call-hook Foo) (- hook-foo 1))))