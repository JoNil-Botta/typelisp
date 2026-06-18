(import "stdlib/comptime.tl" module stdlib.comptime as comptime)

(defmacro (stdlib-comptime-id [x : comptime.Expr]) : i64
  x)

(defmacro (stdlib-comptime-first-or-zero [args : comptime.Expr ...]) : i64
  (if (comptime.expr-list-empty? args)
    (comptime.expr-int 0)
    (comptime.expr-list-head args)))

(defmacro (stdlib-comptime-match-int-or-zero [x : comptime.Expr]) : i64
  (match x
    [(ExprInt _) x]
    [_ (comptime.expr-int 0)]))

(defmacro (stdlib-comptime-arg-count [args : comptime.Expr ...]) : i64
  (comptime.expr-int (comptime.expr-list-length args)))

(defmacro (stdlib-comptime-clause-count [arms : comptime.ExprClause ...]) : i64
  (comptime.expr-int
    (comptime.expr-list-length (comptime.expr-clause-list->expr-list arms))))

(define (stdlib-comptime-qualified-import-shape) : i64
  (+
    (stdlib-comptime-id 14)
    (+
      (stdlib-comptime-first-or-zero 14 100)
      (stdlib-comptime-match-int-or-zero 14))))

(define (stdlib-comptime-qualified-helper-shape) : i64
  (+
    (stdlib-comptime-arg-count 1 2 3)
    (+ (stdlib-comptime-clause-count [false 0] [true 0] [false 0]) 36)))

(test
  comptime-qualified-import-shape
  (if (= (stdlib-comptime-qualified-import-shape) 42)
    unit
    (begin
      (/ 1 0)
      unit)))

(test
  comptime-qualified-helper-shape
  (if (= (stdlib-comptime-qualified-helper-shape) 42)
    unit
    (begin
      (/ 1 0)
      unit)))