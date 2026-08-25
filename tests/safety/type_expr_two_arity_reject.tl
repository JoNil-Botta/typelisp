(import stdlib.comptime)

(define value : Expr
  (comptime (comptime.type-expr (type i64) (type bool))))