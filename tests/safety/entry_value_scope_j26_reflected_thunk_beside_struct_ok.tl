;; #9687: a reflected callable entry global beside a same-named struct.
(import stdlib.comptime)

(defstruct U
  (x i64))

(define (right) : i64
  42)

(define same : (-> i64)
  right)

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.sw)
    (import stdlib.comptime)
    (defstruct same
      (q bool))
    (defmacro (rvc [UU : type]) : Expr
      (comptime.expr-call
        (comptime.module-value-expr (type-nominal-module UU) "same")
        (comptime.expr-list-empty)))
    (define (call-it) : i64
      (rvc ,T))))

(import (gen U) as g)

(define (main) : i64
  (g.call-it))