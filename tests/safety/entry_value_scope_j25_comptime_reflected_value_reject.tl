;; #9687: a reflected entry value read at compile time.
(import stdlib.comptime)

(defstruct U
  (x i64))

(define same : i64
  42)

(defmacro (rvv [UU : type]) : Expr
  (comptime.module-value-expr (type-nominal-module UU) "same"))

(define (main) : i64
  (comptime (rvv U)))