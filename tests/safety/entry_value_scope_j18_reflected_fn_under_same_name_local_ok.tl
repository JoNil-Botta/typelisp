;; #9687: a reflected entry function called in the entry module under a same-named local.
(import stdlib.comptime)

(defstruct U
  (x i64))

(define (same [x : i64]) : i64
  (+ x 1))

(defmacro (invoke [T : type] [args : Expr ...]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module T) "same")
    args))

(define (main) : i64
  (let
    [same : (-> f64 i64)
      (lambda ([x : f64]) : i64
        7)]
    (invoke U 41)))