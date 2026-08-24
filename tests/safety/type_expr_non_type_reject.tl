(import stdlib.comptime)

(define value : Expr
  (comptime (comptime.type-expr 1)))