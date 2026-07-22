;; Capability probe for the temporary published-stage0 spelling bridge.
(import stdlib.comptime)

(define (bootstrap-comptime-short-variant-probe [value : comptime.Expr]) : bool
  (match value
    [(comptime.Expr.Var _) true]
    [_ false]))

(define (main) : i64
  0)