(import stdlib.comptime)

(define (main) : Expr
  (comptime.type-expr (quote i64)))