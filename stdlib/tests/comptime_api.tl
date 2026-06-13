(import "stdlib/comptime.tl" module stdlib.comptime as comptime)

(defmacro (stdlib-comptime-id [x : comptime.Expr]) : i64
  x)

(defmacro (stdlib-comptime-first-or-zero [args : comptime.Expr ...]) : i64
  (if (expr-list-empty? args)
    (expr-int 0)
    (expr-list-head args)))

(define (main) : i64
  (+ (stdlib-comptime-id 21) (stdlib-comptime-first-or-zero 21 100)))