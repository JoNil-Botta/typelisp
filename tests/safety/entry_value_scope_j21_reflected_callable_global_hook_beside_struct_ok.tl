;; #9687: the same through module-hook.
(import stdlib.comptime)

(defstruct U
  (x i64))

(define (right [x : i64]) : i64
  (+ x 1))

(define same : (-> i64 i64)
  right)

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.review)
    (import stdlib.comptime)
    (defstruct same
      (x i64))
    (defmacro (invoke [A : type] [args : Expr ...]) : Expr
      (comptime.expr-call
        (comptime.module-hook (type-nominal-module A) "same")
        args))
    (define (call-it) : i64
      (invoke ,T 41))))

(import (gen U) as g)

(define (main) : i64
  (g.call-it))