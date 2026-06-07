;# Core expression macros - the implicit prelude (#2060).
;#
;# The compile driver links this module into every program (alongside
;# stdlib/runtime.tl), so a bare `when`, `unless`, `cond`, or n-ary `and`/`or`
;# that is not bound locally resolves to these macros without an import. Local
;# macros and explicit imports shadow the prelude. (The parser still owns the
;# two-argument `and`/`or` binary forms pending the builtin removal in #1141.)
;#
;# The qualified surface remains available for explicit callers; the import only
;# adds the `core/` alias since the macros are already in scope:
;#
;# Usage: `(import "stdlib/core_macros.tl" module stdlib.core-macros as core)`
;#
;# ```typelisp
;# (import "stdlib/core_macros.tl" module stdlib.core-macros as core)
;#
;# (define (main) : i64
;#   (let
;#     [value : i64 0]
;#     (begin
;#       (core/and true true)
;#       (core/or false true)
;#       (core/when true (set! value 21))
;#       (core/unless false (set! value (+ value 21)))
;#       (set! value (core/cond false 0 true value value))
;#       value)))
;# ```
(module stdlib.core-macros)

;: Short-circuiting boolean conjunction.
;:
;: All operands must be bool-valued. With no operands, this macro expands to
;: `true`.
(defmacro
  (and [args : bool ...])
  :
  bool
  (if (expr-list-empty? args)
    (expr-bool true)
    `(if ,(expr-list-head args)
      (and ,@(expr-list-tail args))
      false)))

;: Short-circuiting boolean disjunction.
;:
;: All operands must be bool-valued. With no operands, this macro expands to
;: `false`.
(defmacro
  (or [args : bool ...])
  :
  bool
  (if (expr-list-empty? args)
    (expr-bool false)
    `(if ,(expr-list-head args)
      true
      (or ,@(expr-list-tail args)))))

;: Evaluate `body` only when `condition` is true.
;:
;: `body` must be a unit-valued expression. Use an explicit `begin` when more
;: than one expression should run in the guarded branch.
(defmacro
  (when [condition : bool] [body : unit])
  :
  unit
  `(if ,condition
    ,body
    unit))

;: Evaluate `body` only when `condition` is false.
;:
;: `body` must be a unit-valued expression. Use an explicit `begin` when more
;: than one expression should run in the guarded branch.
(defmacro
  (unless [condition : bool] [body : unit])
  :
  unit
  `(if ,condition
    unit
    ,body))

;: Flat conditional expression macro.
;:
;: Arguments are `test result` pairs followed by a final fallback expression,
;: for example `(core/cond test1 value1 test2 value2 fallback)`. Conditions and
;: results are captured as `Expr` operands; the expanded `if` chain performs the
;: ordinary post-expansion bool/result typechecking.
(defmacro
  (cond [args : Expr ...])
  :
  Expr
  (let
    [arity : i64 (expr-list-length args)]
    (cond
      [(< arity 3) (expr-var "core-cond-invalid-arity")]
      [(= (* (/ arity 2) 2) arity) (expr-var "core-cond-invalid-arity")]
      [(= arity 3)
        `(if ,(expr-list-nth args 0)
          ,(expr-list-nth args 1)
          ,(expr-list-nth args 2))]
      [else
        `(if ,(expr-list-nth args 0)
          ,(expr-list-nth args 1)
          (cond ,@(expr-list-tail (expr-list-tail args))))])))

(export (macro and))

(export (macro or))

(export (macro when))

(export (macro unless))

(export (macro cond))