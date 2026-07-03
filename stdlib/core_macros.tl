;# Core expression macros - the implicit prelude (#2060).
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
(module stdlib.core_macros)

(import stdlib.comptime)

;: Short-circuiting boolean conjunction.
;:
;: All operands must be bool-valued. With no operands, this macro expands to
;: `true`.
(defmacro (and [args : bool ...]) : bool
  `(core-and-from (__core-and-args ,@args) 0))

;: Internal index step for `and`: emit the short-circuiting if-chain over the
;: carrier's operands, read by index (`expr-list-nth`) instead of a shrinking
;: tail. `carrier` wraps the operands in a marker call built once by `and`.
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
  `(core-or-from (__core-or-args ,@args) 0))

;: Internal index step for `or`: emit the short-circuiting if-chain over the
;: carrier's operands, read by index (`expr-list-nth`) instead of a shrinking
;: tail. `carrier` wraps the operands in a marker call built once by `or`.
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
  `(core-cond-from 0 ,@(comptime.expr-clause-list->expr-list arms)))

;: Internal index step for `cond`: read clauses by index (`expr-clause-list-nth`)
;: instead of peeling a tail. `idx` is the current clause position and the full
;: clause list is threaded so each step can address the remaining arms.
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

(test
  core-macros-api
  (let
    [value : i64 0]
    [short : i64 0]
    (begin
      (if (and)
        unit
        (begin
          (/ 1 0)
          unit))
      (if (and true)
        unit
        (begin
          (/ 1 0)
          unit))
      (if (and true true true)
        unit
        (begin
          (/ 1 0)
          unit))
      (if (not (and true false true))
        unit
        (begin
          (/ 1 0)
          unit))
      (if (not (or))
        unit
        (begin
          (/ 1 0)
          unit))
      (if (or true)
        unit
        (begin
          (/ 1 0)
          unit))
      (if (or false true false)
        unit
        (begin
          (/ 1 0)
          unit))
      (if (not (or false false false))
        unit
        (begin
          (/ 1 0)
          unit))
      (when true (set! value 1))
      (when false (set! value 1000))
      (unless false (set! value (+ value 41)))
      (unless true (set! value 1000))
      (if (= value 42)
        unit
        (begin
          (/ 1 0)
          unit))
      (if (= (cond [(< -1 0) 7] [(= -1 0) 8] [else 9]) 7)
        unit
        (begin
          (/ 1 0)
          unit))
      (if (= (cond [false 7] [else 42]) 42)
        unit
        (begin
          (/ 1 0)
          unit))
      (if (cond [true true] [else false])
        unit
        (begin
          (/ 1 0)
          unit))
      (cond [true unit] [else unit])
      (if (and
        true
        false
        (begin
          (set! short 1000)
          true))
        (set! short 1000)
        unit)
      (if (or
        true
        (begin
          (set! short 1000)
          false))
        unit
        (set! short 1000))
      (if (= short 0)
        unit
        (begin
          (/ 1 0)
          unit)))))