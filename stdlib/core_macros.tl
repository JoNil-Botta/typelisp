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
;: Short-circuiting boolean conjunction.
;:
;: All operands must be bool-valued. With no operands, this macro expands to
;: `true`.
(module stdlib.core_macros)

(defmacro (and [args : bool ...]) : bool
  (if (expr-list-empty? args)
    (expr-bool true)
    `(if ,(expr-list-head args)
      (and ,@(expr-list-tail args))
      false)))

;: Short-circuiting boolean disjunction.
;:
;: All operands must be bool-valued. With no operands, this macro expands to
;: `false`.
(defmacro (or [args : bool ...]) : bool
  (if (expr-list-empty? args)
    (expr-bool false)
    `(if ,(expr-list-head args)
      true
      (or ,@(expr-list-tail args)))))

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
  (if (expr-clause-list-empty? arms)
    (expr-var "core-cond-missing-else")
    (let
      [arm : ExprClause (expr-clause-list-head arms)]
      [rest : ExprClauseList (expr-clause-list-tail arms)]
      (match (expr-clause-first arm)
        [(ExprVar name)
          (if (string-eq name "else")
            (if (expr-clause-list-empty? rest)
              (expr-clause-second arm)
              (expr-var "core-cond-else-must-be-final"))
            (if (expr-clause-list-empty? rest)
              (expr-var "core-cond-missing-else")
              `(if ,(expr-clause-first arm)
                ,(expr-clause-second arm)
                (cond ,@(expr-clause-list->expr-list rest)))))]
        [_
          (if (expr-clause-list-empty? rest)
            (expr-var "core-cond-missing-else")
            `(if ,(expr-clause-first arm)
              ,(expr-clause-second arm)
              (cond ,@(expr-clause-list->expr-list rest))))]))))

(export (macro and))

(export (macro or))

(export (macro when))

(export (macro unless))

(export (macro cond))