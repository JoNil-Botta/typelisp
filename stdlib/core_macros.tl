;# Core expression macros - the implicit prelude (#2060).
;#
;# The compile driver links this module into every program (alongside
;# stdlib/runtime.tl), so a bare `when`, `unless`, `cond`, `and`, or `or` that is
;# not bound locally resolves to these macros without an import. Local macros
;# and explicit imports shadow the prelude.
;#
;# ```typelisp
;# (define (main) : i64
;#   (let
;#     [value : i64 0]
;#     (begin
;#       (and true true)
;#       (or false true)
;#       (when true (set! value 21))
;#       (unless false (set! value (+ value 21)))
;#       (set! value (cond false 0 true value value))
;#       value)))
;# ```
(module stdlib.core_macros)

;: Short-circuiting boolean conjunction.
;:
;: All operands must be bool-valued. With no operands, this macro expands to
;: `true`.
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

;: Flat conditional expression macro.
;:
;: Arguments are `test result` pairs followed by a final fallback expression,
;: for example `(cond test1 value1 test2 value2 fallback)`. Conditions and
;: results are captured as `Expr` operands; the expanded `if` chain performs the
;: ordinary post-expansion bool/result typechecking.
(defmacro (cond [args : Expr ...]) : Expr
  (let
    [arity : i64 (expr-list-length args)]
    [invalid-arity? : bool
      (if (< arity 3)
        true
        (= (* (/ arity 2) 2) arity))]
    (if invalid-arity?
      (expr-var "core-cond-invalid-arity")
      (if (= arity 3)
        `(if ,(expr-list-nth args 0)
          ,(expr-list-nth args 1)
          ,(expr-list-nth args 2))
        `(if ,(expr-list-nth args 0)
          ,(expr-list-nth args 1)
          (cond ,@(expr-list-tail (expr-list-tail args))))))))

(export (macro and))

(export (macro or))

(export (macro when))

(export (macro unless))

(export (macro cond))