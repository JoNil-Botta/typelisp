;# Core expression macros - the implicit prelude.
;#
;# The compile driver links this module into every program (alongside
;# stdlib/runtime.tl), so a bare `when`, `unless`, `cond`, `and`, or `or` that is
;# not bound locally resolves to these macros without an import. Local macros
;# and explicit imports shadow the prelude.
;#
;# ```lisp
;# (define (main) : i64
;#   (let
;#     [value : i64 0]
;#     (begin
;#       (and true true)
;#       (or false true)
;#       (when true (set! value 21))
;#       (unless false (set! value (+ value 21)))
;#       (set! value (cond [false 0] [true value] [else value]))
;#       value)))
;# ```
(import stdlib.comptime)

;; Bootstrap-only legacy prelude for a seed that predates CTFE `while`.
;; `scripts/lib-bootstrap-ctfe.sh` selects this file only for seed -> stage1.
;; Keep ordinary compiler invocations on stdlib/core_macros.tl instead.
;: Short-circuiting boolean conjunction.
;:
;: All operands must be bool-valued. With no operands, this macro expands to
;: `true`.
(defmacro (and [args : bool ...]) : bool
  (match (comptime.expr-list-length args)
    [0 (comptime.expr-bool true)]
    [1
      `(if ,(comptime.expr-list-nth args 0)
        true
        false)]
    [2
      `(if ,(comptime.expr-list-nth args 0)
        (if ,(comptime.expr-list-nth args 1)
          true
          false)
        false)]
    [3
      `(if ,(comptime.expr-list-nth args 0)
        (if ,(comptime.expr-list-nth args 1)
          (if ,(comptime.expr-list-nth args 2)
            true
            false)
          false)
        false)]
    [4
      `(if ,(comptime.expr-list-nth args 0)
        (if ,(comptime.expr-list-nth args 1)
          (if ,(comptime.expr-list-nth args 2)
            (if ,(comptime.expr-list-nth args 3)
              true
              false)
            false)
          false)
        false)]
    [5
      `(if ,(comptime.expr-list-nth args 0)
        (if ,(comptime.expr-list-nth args 1)
          (if ,(comptime.expr-list-nth args 2)
            (if ,(comptime.expr-list-nth args 3)
              (if ,(comptime.expr-list-nth args 4)
                true
                false)
              false)
            false)
          false)
        false)]
    [_ `(core-and-from (__core-and-args ,@args) 0)]))

;: Compatibility entry for the old indexed `and` expansion helper.
(defmacro (core-and-from [carrier : comptime.Expr] [idx : comptime.Expr]) : bool
  (match idx
    [(comptime.ExprInt i)
      (match carrier
        [(comptime.ExprCall _ elems)
          (if (>= i (comptime.expr-list-length elems))
            (comptime.expr-bool true)
            `(if ,(comptime.expr-list-nth elems i)
              (core-and-from ,carrier ,(comptime.expr-int (+ i 1)))
              false))]
        [_ (comptime.expr-bool true)])]
    [_ (comptime.expr-bool true)]))

;: Short-circuiting boolean disjunction.
;:
;: All operands must be bool-valued. With no operands, this macro expands to
;: `false`.
(defmacro (or [args : bool ...]) : bool
  (match (comptime.expr-list-length args)
    [0 (comptime.expr-bool false)]
    [1
      `(if ,(comptime.expr-list-nth args 0)
        true
        false)]
    [2
      `(if ,(comptime.expr-list-nth args 0)
        true
        (if ,(comptime.expr-list-nth args 1)
          true
          false))]
    [3
      `(if ,(comptime.expr-list-nth args 0)
        true
        (if ,(comptime.expr-list-nth args 1)
          true
          (if ,(comptime.expr-list-nth args 2)
            true
            false)))]
    [4
      `(if ,(comptime.expr-list-nth args 0)
        true
        (if ,(comptime.expr-list-nth args 1)
          true
          (if ,(comptime.expr-list-nth args 2)
            true
            (if ,(comptime.expr-list-nth args 3)
              true
              false))))]
    [5
      `(if ,(comptime.expr-list-nth args 0)
        true
        (if ,(comptime.expr-list-nth args 1)
          true
          (if ,(comptime.expr-list-nth args 2)
            true
            (if ,(comptime.expr-list-nth args 3)
              true
              (if ,(comptime.expr-list-nth args 4)
                true
                false)))))]
    [_ `(core-or-from (__core-or-args ,@args) 0)]))

;: Compatibility entry for the old indexed `or` expansion helper.
(defmacro (core-or-from [carrier : comptime.Expr] [idx : comptime.Expr]) : bool
  (match idx
    [(comptime.ExprInt i)
      (match carrier
        [(comptime.ExprCall _ elems)
          (if (>= i (comptime.expr-list-length elems))
            (comptime.expr-bool false)
            `(if ,(comptime.expr-list-nth elems i)
              true
              (core-or-from ,carrier ,(comptime.expr-int (+ i 1)))))]
        [_ (comptime.expr-bool false)])]
    [_ (comptime.expr-bool false)]))

;: Evaluate `body` expressions only when `condition` is true.
;:
;: Each body expression must be unit-valued.
(defmacro (when [condition : bool] [body : unit ...]) : unit
  (if (= (comptime.expr-list-length body) 0)
    (comptime.expr-var "core-when-missing-body")
    `(if ,condition
      (begin
        ,@body)
      unit)))

;: Evaluate `body` expressions only when `condition` is false.
;:
;: Each body expression must be unit-valued.
(defmacro (unless [condition : bool] [body : unit ...]) : unit
  (if (= (comptime.expr-list-length body) 0)
    (comptime.expr-var "core-unless-missing-body")
    `(if ,condition
      unit
      (begin
        ,@body))))

;: Bracket-arm conditional expression macro.
;:
;: Arguments are bracket clauses, ending with `[else fallback]`, for example
;: `(cond [test1 value1] [test2 value2] [else fallback])`. Conditions and
;: results are captured as `ExprClause` operands; the expanded `if` chain
;: performs the ordinary post-expansion bool/result typechecking.
(defmacro (cond [arms : ExprClause ...]) : Expr
  (match (comptime.expr-clause-list-length arms)
    [0 (comptime.expr-var "core-cond-missing-else")]
    [1
      (match (comptime.expr-clause-list-nth arms 0)
        [(ExprClause test result)
          (match test
            [(comptime.ExprVar name)
              (if (string-eq name "else")
                result
                (comptime.expr-var "core-cond-missing-else"))]
            [_ (comptime.expr-var "core-cond-missing-else")])])]
    [2
      (let
        [fallback : comptime.Expr
          (match (comptime.expr-clause-list-nth arms 1)
            [(ExprClause test result)
              (match test
                [(comptime.ExprVar name)
                  (if (string-eq name "else")
                    result
                    (comptime.expr-var "core-cond-missing-else"))]
                [_ (comptime.expr-var "core-cond-missing-else")])])]
        (match (comptime.expr-clause-list-nth arms 0)
          [(ExprClause test result)
            (match test
              [(comptime.ExprVar name)
                (if (string-eq name "else")
                  (comptime.expr-var "core-cond-else-must-be-final")
                  `(if ,test
                    ,result
                    ,fallback))]
              [_
                `(if ,test
                  ,result
                  ,fallback)])]))]
    [_ `(core-cond-from 0 ,@(comptime.expr-clause-list->expr-list arms))]))

;: Compatibility entry for the old indexed `cond` expansion helper.
(defmacro (core-cond-from [idx : comptime.Expr] [arms : ExprClause ...]) : Expr
  (match idx
    [(comptime.ExprInt i)
      (let
        [n : i64 (comptime.expr-clause-list-length arms)]
        (if (>= i n)
          (comptime.expr-var "core-cond-missing-else")
          (match (comptime.expr-clause-list-nth arms i)
            [(ExprClause test result)
              (match test
                [(comptime.ExprVar name)
                  (if (string-eq name "else")
                    (if (= (+ i 1) n)
                      result
                      (comptime.expr-var "core-cond-else-must-be-final"))
                    (if (= (+ i 1) n)
                      (comptime.expr-var "core-cond-missing-else")
                      `(if ,test
                        ,result
                        (core-cond-from
                          ,(comptime.expr-int (+ i 1))
                          ,@(comptime.expr-clause-list->expr-list arms)))))]
                [_
                  (if (= (+ i 1) n)
                    (comptime.expr-var "core-cond-missing-else")
                    `(if ,test
                      ,result
                      (core-cond-from
                        ,(comptime.expr-int (+ i 1))
                        ,@(comptime.expr-clause-list->expr-list arms))))])])))]
    [_ (comptime.expr-var "core-cond-missing-else")]))