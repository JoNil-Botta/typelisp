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
  (if (comptime.expr-list-empty? args)
    (comptime.expr-bool true)
    `(if ,(comptime.expr-list-head args)
      (and ,@(comptime.expr-list-tail args))
      false)))

;: Short-circuiting boolean disjunction.
;:
;: All operands must be bool-valued. With no operands, this macro expands to
;: `false`.
(defmacro (or [args : bool ...]) : bool
  (if (comptime.expr-list-empty? args)
    (comptime.expr-bool false)
    `(if ,(comptime.expr-list-head args)
      true
      (or ,@(comptime.expr-list-tail args)))))

;: Evaluate `body` only when `condition` is true.
;:
;: `body` must be a unit-valued expression. Use an explicit `begin` when more
;: than one expression should run in the guarded branch.
(defmacro (when [condition : bool] [body : unit]) : unit
  `(if ,condition
    ,body
    unit))

;: Evaluate `body` only when `condition` is false.
;:
;: `body` must be a unit-valued expression. Use an explicit `begin` when more
;: than one expression should run in the guarded branch.
(defmacro (unless [condition : bool] [body : unit]) : unit
  `(if ,condition
    unit
    ,body))

;: Bracket-arm conditional expression macro.
;:
;: Arguments are bracket clauses, ending with `[else fallback]`, for example
;: `(cond [test1 value1] [test2 value2] [else fallback])`. Conditions and
;: results are captured as `ExprClause` operands; the expanded `if` chain
;: performs the ordinary post-expansion bool/result typechecking.
(defmacro (cond [arms : ExprClause ...]) : Expr
  (if (comptime.expr-clause-list-empty? arms)
    (comptime.expr-var "core-cond-missing-else")
    (let
      [arm : ExprClause (comptime.expr-clause-list-head arms)]
      [rest : ExprClauseList (comptime.expr-clause-list-tail arms)]
      (match arm
        [(ExprClause test result)
          (match test
            [(ExprVar name)
              (if (string-eq name "else")
                (if (comptime.expr-clause-list-empty? rest)
                  result
                  (comptime.expr-var "core-cond-else-must-be-final"))
                (if (comptime.expr-clause-list-empty? rest)
                  (comptime.expr-var "core-cond-missing-else")
                  `(if ,test
                    ,result
                    (cond ,@(comptime.expr-clause-list->expr-list rest)))))]
            [_
              (if (comptime.expr-clause-list-empty? rest)
                (comptime.expr-var "core-cond-missing-else")
                `(if ,test
                  ,result
                  (cond ,@(comptime.expr-clause-list->expr-list rest))))])]))))

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