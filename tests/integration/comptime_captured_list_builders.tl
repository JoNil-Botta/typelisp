(import stdlib.comptime)

(define (sum [left : i64] [right : i64]) : i64
  (+ left right))

;; Each macro below takes a binding-clause prefix, so its trailing operands
;; reach the transformer as a captured caller list, as the prelude `for` body
;; does.
(defmacro (prefix
  [_bindings : comptime.ExprBindingClause ...]
  [body : comptime.Expr ...]) : unit
  `,(comptime.expr-begin-unit
    (comptime.expr-list-cons (comptime.expr-int 0) body)))

(defmacro (call-sum
  [_bindings : comptime.ExprBindingClause ...]
  [args : comptime.Expr ...]) : i64
  `,(comptime.expr-call `sum args))

(defmacro (prefix-sum
  [_bindings : comptime.ExprBindingClause ...]
  [args : comptime.Expr ...]) : i64
  `,(comptime.expr-call
    `sum
    (comptime.expr-list-cons (comptime.expr-int 20) args)))

(defmacro (first-prefixed
  [_bindings : comptime.ExprBindingClause ...]
  [args : comptime.Expr ...]) : i64
  `,(comptime.expr-list-nth
    (comptime.expr-list-cons (comptime.expr-int 42) args)
    0))

(defmacro (splice-prefixed
  [_bindings : comptime.ExprBindingClause ...]
  [body : comptime.Expr ...]) : unit
  (let
    [items : comptime.ExprList
      (comptime.expr-list-cons (comptime.expr-int 0) body)]
    `(begin
      ,@items
      unit)))

;; The operand list is reused after the call is built from it.
(defmacro (call-then-body
  [_bindings : comptime.ExprBindingClause ...]
  [args : comptime.Expr ...]) : i64
  (let
    [call : comptime.Expr (comptime.expr-call `sum args)]
    [body : comptime.Expr (comptime.expr-begin-unit args)]
    `(begin
      ,body
      ,call)))

(define (check-builders) : i64
  (let
    [order : i64 0]
    (prefix [x 1])
    (prefix
      [x 1]
      (set! order (+ (* order 10) 1))
      (prefix [y 2] (set! order (+ (* order 10) 2))))
    (splice-prefixed [z 3] (set! order (+ (* order 10) 3)))
    (if (and
      (= order 123)
      (= (call-sum [x 1] 20 22) 42)
      (= (prefix-sum [x 1] 22) 42)
      (= (first-prefixed [x 1]) 42)
      (= (first-prefixed [x 1] 7 8 9) 42)
      (= (call-then-body [x 1] (+ order 0) (- 42 123)) 42))
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