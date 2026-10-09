;; comptime_expr_call_args.tl - `comptime.expr-call-args` returns the
;; argument expressions of a call expression, looking through spans and
;; caller-origin markers, and an empty list for any other expression.
(import stdlib.comptime)
(import stdlib.iterator)

;; The number of arguments of the first clause's initializer when it is a call.
(defmacro (init-arg-count [clauses : ExprBindingClause ...]) : i64
  (comptime.expr-int
    (comptime.expr-list-length
      (comptime.expr-call-args
        (comptime.expr-binding-clause-init
          (comptime.expr-binding-clause-list-nth clauses 0))))))

;; The last argument of a call operand, or 0 when it has none.
(defmacro (last-arg [value : Expr]) : i64
  (let
    [args : ExprList (comptime.expr-call-args value)]
    [count : i64 (comptime.expr-list-length args)]
    (if (> count 0)
      (comptime.expr-list-nth args (- count 1))
      (comptime.expr-int 0))))

(define (subtract [first : i64] [last : i64]) : i64
  (- last first))

(define (nothing) : i64
  0)

(define (check [ok : bool]) : i64
  (if ok
    0
    1))

(define (main) : i64
  (if (=
    (+
      ;; A call, also through an import alias and with a typed clause.
      (check (= (init-arg-count [x (iterator.range 0 3)]) 2))
      (check (= (init-arg-count [x : i64 (subtract 1 (subtract 2 3))]) 2))
      ;; A call with no arguments, and not a call at all.
      (check (= (init-arg-count [x (nothing)]) 0))
      (check (= (init-arg-count [x 5]) 0))
      ;; The arguments are the call's own expressions.
      (check (= (last-arg (subtract 5 9)) 9))
      (check (= (last-arg (subtract 5 (subtract 1 4))) 3))
      (check (= (last-arg (nothing)) 0))
      (check (= (last-arg 7) 0)))
    0)
    42
    1))