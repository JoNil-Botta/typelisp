;# Core expression macros - the implicit prelude.
;#
;# The compile driver links this module into every program (alongside
;# stdlib/runtime.tl), so a bare `when`, `unless`, `cond`, `and`, or `or` that is
;# not bound locally resolves to these macros without an import. `for` is the
;# scalar iterator loop; it remains distinct from SPMD `foreach`. Local macros
;# and explicit imports shadow the prelude.
;#
;# ```lisp
;# (import stdlib.iterator)
;#
;# (define (main) : i64
;#   (let
;#     [value : i64 0]
;#     (begin
;#       (and true true)
;#       (or false true)
;#       (when true (set! value 21))
;#       (unless false (set! value (+ value 21)))
;#       (for [item (iterator.range 0 0)] (set! value (+ value item)))
;#       (set! value (cond [false 0] [true value] [else value]))
;#       value)))
;# ```
(import stdlib.comptime)

;; lint-allow: unused-import -- loads the typed clone declaration producer.
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
                    [(comptime.Expr.Var name)
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
                            [(comptime.Expr.Var name)
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

;: Traverse one or more scalar iterables with zip-shortest semantics.
;:
;: Leading operands are let-like clauses, `[name source]` or
;: `[name : ItemType source]`, followed by one or more unit-valued body
;: expressions. Every source is evaluated once and every iterator state is
;: constructed once.
;: A shared source selects `iterator` / `next`, a mutable source selects
;: `iterator-mut` / `next-mut`, and an owned source selects
;: `into-iterator` / `into-next` from the source type's defining module.
;: Cleanup-owning items unwind in reverse acquisition order when a later zipped
;: iterator is done or control leaves the body. Moving an item transfers cleanup
;: responsibility and disarms its generated resource scope.
(cfg
  feature-stdlib-for-defmacro
  (defmacro (for [bindings : ExprBindingClause ...] [body : Expr ...]) : unit
    (let
      [binding-count : i64 (comptime.expr-binding-clause-list-length bindings)]
      [body-count : i64 (comptime.expr-list-length body)]
      (if (= binding-count 0)
        (comptime.comptime-error
          "typecheck: for expects at least one leading binding clause [name source] or [name : Type source]")
        (if (= body-count 0)
          (comptime.comptime-error
            "typecheck: for expects at least one body expression after its binding clauses")
          (let
            [done-name : String (comptime.syntax-name-fresh "__for_done_0")]
            [done-var : comptime.Expr (comptime.expr-var done-name)]
            [out : comptime.Expr (comptime.expr-begin-unit body)]
            [index : i64 (- binding-count 1)]
            (begin
              ;; Validate every protocol before constructing syntax. Keeping the
              ;; checks in one lexical frame avoids retaining a deep tower of
              ;; type environments while this ordinary transformer is checked.
              (while (>= index 0)
                (let
                  [binding : comptime.ExprBindingClause
                    (comptime.expr-binding-clause-list-nth bindings index)]
                  [source : comptime.Expr
                    (comptime.expr-binding-clause-init binding)]
                  [source-type : comptime.Expr (comptime.expr-type source)]
                  [source-kind : String (type-kind source-type)]
                  [referent-type : comptime.Expr
                    (if (if (string-eq source-kind "ref")
                      true
                      (string-eq source-kind "mut-ref"))
                      (comptime.reference-element-type source-type)
                      source-type)]
                  [referent-kind : String (type-kind referent-type)]
                  [_source-nominal : unit
                    (if (if (string-eq referent-kind "struct")
                      true
                      (string-eq referent-kind "enum"))
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for source "
                          (comptime.string-append
                            (type-key source-type)
                            " must be a nominal iterable or reference to one"))))]
                  [module : String (type-nominal-module referent-type)]
                  [constructor-name : String
                    (if (string-eq source-kind "ref")
                      "iterator"
                      (if (string-eq source-kind "mut-ref")
                        "iterator-mut"
                        "into-iterator"))]
                  [next-name : String
                    (if (string-eq source-kind "ref")
                      "next"
                      (if (string-eq source-kind "mut-ref")
                        "next-mut"
                        "into-next"))]
                  [constructor-display : String
                    (if (string-eq module "")
                      constructor-name
                      (comptime.string-append
                        module
                        (comptime.string-append "." constructor-name)))]
                  [next-display : String
                    (if (string-eq module "")
                      next-name
                      (comptime.string-append
                        module
                        (comptime.string-append "." next-name)))]
                  [constructor-type : comptime.Expr
                    (if (comptime.module-value? module constructor-name)
                      (comptime.module-value-type module constructor-name)
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for source "
                          (comptime.string-append
                            (type-key source-type)
                            (comptime.string-append
                              " is missing protocol function "
                              constructor-display)))))]
                  [next-type : comptime.Expr
                    (if (comptime.module-value? module next-name)
                      (comptime.module-value-type module next-name)
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for source "
                          (comptime.string-append
                            (type-key source-type)
                            (comptime.string-append
                              " is missing protocol function "
                              next-display)))))]
                  [_constructor-callable : unit
                    (if (string-eq (type-kind constructor-type) "function")
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for protocol function "
                          (comptime.string-append
                            constructor-display
                            " is not callable"))))]
                  [_constructor-arity : unit
                    (if (= (function-param-count constructor-type) 1)
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for protocol function "
                          (comptime.string-append
                            constructor-display
                            " must take exactly one source argument"))))]
                  [_next-callable : unit
                    (if (string-eq (type-kind next-type) "function")
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for protocol function "
                          (comptime.string-append
                            next-display
                            " is not callable"))))]
                  [_next-arity : unit
                    (if (= (function-param-count next-type) 1)
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for protocol function "
                          (comptime.string-append
                            next-display
                            " must take exactly one iterator argument"))))]
                  [next-result : comptime.Expr (function-return-type next-type)]
                  [_next-result-enum : unit
                    (if (string-eq (type-kind next-result) "enum")
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for protocol function "
                          (comptime.string-append
                            next-display
                            (comptime.string-append
                              " for source "
                              (comptime.string-append
                                (type-key source-type)
                                " must return a Done/Item enum"))))))]
                  [variant-count : i64 (enum-variant-count next-result)]
                  [variant-index : i64 0]
                  [done-index : i64 -1]
                  [item-index : i64 -1]
                  (begin
                    (while (< variant-index variant-count)
                      (let
                        [variant-name : String
                          (enum-variant-name next-result variant-index)]
                        (begin
                          (if (string-eq variant-name "Done")
                            (set! done-index variant-index)
                            unit)
                          (if (string-eq variant-name "Item")
                            (set! item-index variant-index)
                            unit)
                          (set! variant-index (+ variant-index 1)))))
                    (if (>= done-index 0)
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for protocol result "
                          (comptime.string-append
                            (type-key next-result)
                            " is missing Done"))))
                    (if (>= item-index 0)
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for protocol result "
                          (comptime.string-append
                            (type-key next-result)
                            " is missing Item"))))
                    (if (=
                      (enum-variant-payload-count next-result item-index)
                      1)
                      unit
                      (comptime.comptime-error
                        "typecheck: for protocol Item must carry exactly one item"))
                    (set! index (- index 1)))))
              ;; Build the zip-shortest match chain from right to left. Every
              ;; earlier Item scope surrounds the later probe, so cleanup
              ;; naturally unwinds in reverse acquisition order.
              (set! index (- binding-count 1))
              (while (>= index 0)
                (let
                  [binding : comptime.ExprBindingClause
                    (comptime.expr-binding-clause-list-nth bindings index)]
                  [source : comptime.Expr
                    (comptime.expr-binding-clause-init binding)]
                  [source-type : comptime.Expr (comptime.expr-type source)]
                  [source-kind : String (type-kind source-type)]
                  [referent-type : comptime.Expr
                    (if (if (string-eq source-kind "ref")
                      true
                      (string-eq source-kind "mut-ref"))
                      (comptime.reference-element-type source-type)
                      source-type)]
                  [module : String (type-nominal-module referent-type)]
                  [next-name : String
                    (if (string-eq source-kind "ref")
                      "next"
                      (if (string-eq source-kind "mut-ref")
                        "next-mut"
                        "into-next"))]
                  [next-display : String
                    (if (string-eq module "")
                      next-name
                      (comptime.string-append
                        module
                        (comptime.string-append "." next-name)))]
                  [next-type : comptime.Expr
                    (comptime.module-value-type module next-name)]
                  [next-result : comptime.Expr (function-return-type next-type)]
                  [variant-count : i64 (enum-variant-count next-result)]
                  [variant-index : i64 0]
                  [item-index : i64 -1]
                  (begin
                    (while (< variant-index variant-count)
                      (begin
                        (if (string-eq
                          (enum-variant-name next-result variant-index)
                          "Item")
                          (set! item-index variant-index)
                          unit)
                        (set! variant-index (+ variant-index 1))))
                    (let
                      [item-type : comptime.Expr
                        (enum-variant-payload-type next-result item-index 0)]
                      [item-cleanup? : bool (type-cleanup-owning? item-type)]
                      [binding-name : String
                        (comptime.expr-binding-clause-name binding)]
                      [payload-name : String
                        (if item-cleanup?
                          (comptime.syntax-name-fresh
                            (comptime.string-append
                              "__for_item_owner_payload_"
                              (comptime.int->string index)))
                          binding-name)]
                      [payload-pattern : comptime.Pattern
                        (if (comptime.expr-binding-clause-has-type? binding)
                          (comptime.pattern-binding-typed
                            payload-name
                            (comptime.expr-binding-clause-type binding))
                          (comptime.pattern-binding payload-name))]
                      [item-body : comptime.Expr
                        (if item-cleanup?
                          (comptime.expr-resource-scope
                            binding-name
                            (comptime.expr-var payload-name)
                            (comptime.expr-var
                              (type-cleanup-function item-type))
                            out
                            true)
                          out)]
                      [done-pattern : comptime.Pattern
                        (comptime.pattern-variant
                          (comptime.string-append
                            (type-nominal-name next-result)
                            ".Done")
                          (comptime.pattern-list-empty))]
                      [item-pattern : comptime.Pattern
                        (comptime.pattern-variant
                          (comptime.string-append
                            (type-nominal-name next-result)
                            ".Item")
                          (comptime.pattern-list-cons
                            payload-pattern
                            (comptime.pattern-list-empty)))]
                      [iterator-name : String
                        (comptime.syntax-name-fresh
                          (comptime.string-append
                            "__for_iterator_"
                            (comptime.int->string index)))]
                      [iterator-var : comptime.Expr
                        (comptime.expr-var iterator-name)]
                      [next-call : comptime.Expr
                        (comptime.expr-call
                          (comptime.expr-var next-display)
                          (comptime.expr-list-cons
                            (comptime.expr-mut-borrow iterator-var)
                            (comptime.expr-list-empty)))]
                      (begin
                        (set!
                          out
                          (comptime.expr-match
                            next-call
                            (comptime.match-arm-list-cons
                              (comptime.match-arm
                                done-pattern
                                (comptime.expr-set-var
                                  done-name
                                  (comptime.expr-bool true)))
                              (comptime.match-arm-list-cons
                                (comptime.match-arm item-pattern item-body)
                                (comptime.match-arm-list-empty)))))
                        (set! index (- index 1)))))))
              (set!
                out
                (comptime.expr-let-scope
                  done-name
                  (comptime.expr-bool false)
                  (comptime.expr-while (comptime.expr-not done-var) out)))
              ;; Wrap iterator construction and cleanup scopes. Re-reflection
              ;; here keeps the implementation in ordinary source values; it
              ;; is measured by the macro-walk gates below.
              (set! index (- binding-count 1))
              (while (>= index 0)
                (let
                  [binding : comptime.ExprBindingClause
                    (comptime.expr-binding-clause-list-nth bindings index)]
                  [source : comptime.Expr
                    (comptime.expr-binding-clause-init binding)]
                  [source-type : comptime.Expr (comptime.expr-type source)]
                  [source-kind : String (type-kind source-type)]
                  [referent-type : comptime.Expr
                    (if (if (string-eq source-kind "ref")
                      true
                      (string-eq source-kind "mut-ref"))
                      (comptime.reference-element-type source-type)
                      source-type)]
                  [module : String (type-nominal-module referent-type)]
                  [constructor-name : String
                    (if (string-eq source-kind "ref")
                      "iterator"
                      (if (string-eq source-kind "mut-ref")
                        "iterator-mut"
                        "into-iterator"))]
                  [constructor-type : comptime.Expr
                    (comptime.module-value-type module constructor-name)]
                  [constructor-display : String
                    (if (string-eq module "")
                      constructor-name
                      (comptime.string-append
                        module
                        (comptime.string-append "." constructor-name)))]
                  [iterator-type : comptime.Expr
                    (function-return-type constructor-type)]
                  [source-temp? : bool
                    (if (string-eq source-kind "mut-ref")
                      false
                      (not (type-cleanup-owning? source-type)))]
                  [source-name : String
                    (comptime.syntax-name-fresh
                      (comptime.string-append
                        "__for_source_"
                        (comptime.int->string index)))]
                  [source-var : comptime.Expr (comptime.expr-var source-name)]
                  [iterator-name : String
                    (comptime.syntax-name-fresh
                      (comptime.string-append
                        "__for_iterator_"
                        (comptime.int->string index)))]
                  [iterator-var : comptime.Expr
                    (comptime.expr-var iterator-name)]
                  [constructor-call : comptime.Expr
                    (comptime.expr-call
                      (comptime.expr-var constructor-display)
                      (comptime.expr-list-cons
                        (if source-temp?
                          source-var
                          source)
                        (comptime.expr-list-empty)))]
                  (begin
                    (set!
                      out
                      (if (type-cleanup-owning? iterator-type)
                        (comptime.expr-resource-scope
                          iterator-name
                          constructor-call
                          (comptime.expr-var
                            (type-cleanup-function iterator-type))
                          out
                          false)
                        (comptime.expr-let-scope
                          iterator-name
                          constructor-call
                          out)))
                    (set! index (- index 1)))))
              ;; Non-owning sources get explicit temporaries so source
              ;; expressions are evaluated exactly once before iterator state.
              (set! index (- binding-count 1))
              (while (>= index 0)
                (let
                  [binding : comptime.ExprBindingClause
                    (comptime.expr-binding-clause-list-nth bindings index)]
                  [source : comptime.Expr
                    (comptime.expr-binding-clause-init binding)]
                  [source-type : comptime.Expr (comptime.expr-type source)]
                  [source-kind : String (type-kind source-type)]
                  [source-temp? : bool
                    (if (string-eq source-kind "mut-ref")
                      false
                      (not (type-cleanup-owning? source-type)))]
                  (begin
                    (if source-temp?
                      (let
                        [source-name : String
                          (comptime.syntax-name-fresh
                            (comptime.string-append
                              "__for_source_"
                              (comptime.int->string index)))]
                        [source-var : comptime.Expr
                          (comptime.expr-var source-name)]
                        (set!
                          out
                          (comptime.expr-let-scope source-name source out)))
                      unit)
                    (set! index (- index 1)))))
              out)))))))

;; Published seed compilers still own the old bootstrap fast path. They do not
;; enable the source-port feature while building the first successor; every
;; successor enables the ordinary declaration above and never sees this stub.
(cfg
  (not feature-stdlib-for-defmacro)
  (defmacro (for [_forms : Expr ...]) : unit
    (comptime.expr-var "unit")))

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