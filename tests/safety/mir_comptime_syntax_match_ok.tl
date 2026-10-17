;; A by-value match on a syntax value moves only the parts its arm binds: the
;; fallback arm still owns the whole value.
(import stdlib.comptime)

(define (condition-or-self [value : Expr]) : Expr
  (match value
    [(Expr.If condition _ _) condition]
    [_ value]))

(define (main) : i64
  0)