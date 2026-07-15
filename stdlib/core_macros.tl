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
(import stdlib.clone)

;: Short-circuiting boolean conjunction.
;:
;: All operands must be bool-valued. With no operands, this macro expands to
;: `true`.
(defmacro (and [args : bool ...]) : bool
  (comptime.expr-list-fold-if
    args
    (comptime.expr-bool true)
    (comptime.expr-bool false)
    true))

;: Short-circuiting boolean disjunction.
;:
;: All operands must be bool-valued. With no operands, this macro expands to
;: `false`.
(defmacro (or [args : bool ...]) : bool
  (comptime.expr-list-fold-if
    args
    (comptime.expr-bool true)
    (comptime.expr-bool false)
    false))

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

(cfg
  test
  (defmacro (core-macros-user-clause-fold [arms : ExprClause ...]) : Expr
    (let
      [n : i64 (comptime.expr-clause-list-length arms)]
      (if (= n 0)
        (comptime.expr-var "core-cond-missing-else")
        (let
          [index : i64 (- n 1)]
          (match (comptime.expr-clause-list-nth arms index)
            [(ExprClause final-test final-result)
              (let
                [out : comptime.Expr
                  (match final-test
                    [(comptime.ExprVar name)
                      (if (string-eq name "else")
                        final-result
                        (comptime.expr-var "core-cond-missing-else"))]
                    [_ (comptime.expr-var "core-cond-missing-else")])]
                (begin
                  (while (> index 0)
                    (begin
                      (set! index (- index 1))
                      (match (comptime.expr-clause-list-nth arms index)
                        [(ExprClause test result)
                          (match test
                            [(comptime.ExprVar name)
                              (if (string-eq name "else")
                                (set!
                                  out
                                  (comptime.expr-var
                                    "core-cond-else-must-be-final"))
                                (set! out (comptime.expr-if test result out)))]
                            [_ (set! out (comptime.expr-if test result out))])])))
                  out))]))))))

;: Bracket-arm conditional expression macro.
;:
;: Arguments are bracket clauses, ending with `[else fallback]`, for example
;: `(cond [test1 value1] [test2 value2] [else fallback])`. Conditions and
;: results are captured as `ExprClause` operands; the expanded `if` chain
;: performs the ordinary post-expansion bool/result typechecking.
(defmacro (cond [arms : ExprClause ...]) : Expr
  (comptime.expr-clause-list-fold-if
    arms
    (comptime.expr-var "core-cond-missing-else")
    (comptime.expr-var "core-cond-else-must-be-final")))

(cfg
  test
  (defmacro (core-macros-user-fold [args : bool ...]) : bool
    (let
      [index : i64 (comptime.expr-list-length args)]
      [out : comptime.Expr (comptime.expr-bool true)]
      (begin
        (while (> index 0)
          (begin
            (set! index (- index 1))
            (set!
              out
              (comptime.expr-if
                (comptime.expr-list-nth args index)
                out
                (comptime.expr-bool false)))))
        out))))

(cfg
  test
  (defmacro (core-macros-user-if-fold [args : bool ...]) : bool
    (comptime.expr-list-fold-if
      args
      (comptime.expr-bool true)
      (comptime.expr-bool false)
      true)))

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
      (if (not
        (and
          true
          true
          true
          true
          true
          true
          false
          (begin
            (set! short 1000)
            true)))
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
      (if (or
        false
        false
        false
        false
        false
        true
        (begin
          (set! short 1000)
          false))
        unit
        (begin
          (/ 1 0)
          unit))
      (if (not
        (core-macros-user-fold
          true
          true
          true
          true
          true
          true
          false
          (begin
            (set! short 1000)
            true)))
        unit
        (begin
          (/ 1 0)
          unit))
      (if (not
        (core-macros-user-if-fold
          true
          true
          true
          true
          true
          true
          false
          (begin
            (set! short 1000)
            true)))
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
      (if (= (cond [false 0] [false 1] [true 42] [else 99]) 42)
        unit
        (begin
          (/ 1 0)
          unit))
      (if (= (core-macros-user-clause-fold [false 0] [else 42]) 42)
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