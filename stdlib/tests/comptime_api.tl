(import "stdlib/comptime.tl" module stdlib.comptime as comptime)

(defmacro (stdlib-comptime-id [x : comptime.Expr]) : i64
  x)

(defmacro (stdlib-comptime-first-or-zero [args : comptime.Expr ...]) : i64
  (if (expr-list-empty? args)
    (expr-int 0)
    (expr-list-head args)))

(defmacro (stdlib-comptime-match-int-or-zero [x : comptime.Expr]) : i64
  (match x
    [(ExprInt _) x]
    [_ (expr-int 0)]))

(define (main) : i64
  (+
    (stdlib-comptime-id 14)
    (+
      (stdlib-comptime-first-or-zero 14 100)
      (stdlib-comptime-match-int-or-zero 14))))