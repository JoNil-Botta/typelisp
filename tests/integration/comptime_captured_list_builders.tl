(import stdlib.comptime)

(define (sum [left : i64] [right : i64]) : i64
  (+ left right))

(defmacro (prefix [body : comptime.Expr ...]) : unit
  `,(comptime.expr-begin-unit
    (comptime.expr-list-cons (comptime.expr-int 0) body)))

(defmacro (call-sum [args : comptime.Expr ...]) : i64
  `,(comptime.expr-call `sum args))

(defmacro (prefix-sum [args : comptime.Expr ...]) : i64
  `,(comptime.expr-call
    `sum
    (comptime.expr-list-cons (comptime.expr-int 20) args)))

(defmacro (first-prefixed [args : comptime.Expr ...]) : i64
  `,(comptime.expr-list-nth
    (comptime.expr-list-cons (comptime.expr-int 42) args)
    0))

(defmacro (splice-prefixed [body : comptime.Expr ...]) : unit
  (let
    [items : comptime.ExprList
      (comptime.expr-list-cons (comptime.expr-int 0) body)]
    `(begin
      ,@items
      unit)))

(define (check-builders) : i64
  (let
    [order : i64 0]
    (prefix)
    (prefix
      (set! order (+ (* order 10) 1))
      (prefix (set! order (+ (* order 10) 2))))
    (splice-prefixed (set! order (+ (* order 10) 3)))
    (if (and
      (= order 123)
      (= (call-sum 20 22) 42)
      (= (prefix-sum 22) 42)
      (= (first-prefixed) 42)
      (= (first-prefixed 7 8 9) 42))
      42
      1)))

(define (main) : i64
  (check-builders))

(test
  captured-list-builders
  (if (= (check-builders) 42)
    unit
    (begin
      (/ 1 0)
      unit)))