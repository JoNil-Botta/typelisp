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

;; Internal migration bridge for compiler/stdlib code that deliberately makes
;; a representation-level shallow copy while converting old sharing APIs to
;; explicit references. Dynamic arrays are indirect handles, so reinterpret
;; the reference cell itself for that case. Other values are loaded through
;; the address carried by the reference. Keeping type reflection on the simple
;; local reference also preserves nested dotted places across macro expansion.
;; The published seed keeps its pre-cutover sharing behavior.
;; lint-allow: function-name-case -- private one-epoch bootstrap ABI
(defmacro (__tl-compiler-owned-shared-view-dyn-ref-as
  [value : Expr]
  ;; Spliced into the generated pointer element type.
  ;; lint-allow: unused-variable
  [value-ty : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-cast (__tl_array-data (array ,value)) : (Ptr ,value-ty)))))

;; Private AST-level bridge for the checked-in seed's pre-dotted global and
;; macro-hygiene resolver. Ordinary source uses direct `value.field` places.
;: Internal bootstrap bridge that projects the named field from `target`.
;:
;: Ordinary source uses direct `target.field` syntax.
;; lint-allow: function-name-case -- private one-epoch bootstrap ABI
(defmacro (__tl-project-field [target : Expr] [field : Expr]) : Expr
  (match field
    [(comptime.Expr.Var name) (comptime.expr-struct-get target name)]
    [_
      (comptime.comptime-error "internal field projection expects a field name")]))

;: Internal bootstrap bridge that assigns `value` to a projected field.
;:
;: Ordinary source uses `(set! target.field value)`.
;; lint-allow: function-name-case -- private one-epoch bootstrap ABI
(defmacro (__tl-project-set-field [target : Expr] [field : Expr] [value : Expr]) : Expr
  (match field
    [(comptime.Expr.Var name) (comptime.expr-struct-set target name value)]
    [_
      (comptime.comptime-error "internal field assignment expects a field name")]))

;; Generated seed templates pass field names as strings so macro hygiene never
;; treats the member name as a binding in the generated module.
;: Internal bootstrap projection bridge whose field operand is a string literal.
;; lint-allow: function-name-case -- private one-epoch bootstrap ABI
(defmacro (__tl-project-field-name [target : Expr] [field : Expr]) : Expr
  (if (comptime.expr-string? field)
    (comptime.expr-struct-get target (comptime.expr-string-value field))
    (comptime.comptime-error
      "internal field projection expects a string literal")))

;: Internal bootstrap assignment bridge whose field operand is a string literal.
;; lint-allow: function-name-case -- private one-epoch bootstrap ABI
(defmacro (__tl-project-set-field-name
  [target : Expr]
  [field : Expr]
  [value : Expr]) : Expr
  (if (comptime.expr-string? field)
    (comptime.expr-struct-set target (comptime.expr-string-value field) value)
    (comptime.comptime-error
      "internal field assignment expects a string literal")))

;; Keep the checked-in seed's legacy BoxGet AST confined to this private
;; one-epoch bridge; public source uses `deref` once rebuilt by the new compiler.
;: Internal bootstrap bridge that projects the value stored in an owned box.
;:
;: Ordinary source uses `(deref value)`.
;; lint-allow: function-name-case -- private one-epoch bootstrap ABI
(defmacro (__tl-box-place [value : Expr]) : Expr
  `(box-get ,value))

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
                [native-source? : bool
                  (if (string-eq referent-kind "array")
                    true
                    (string-eq referent-kind "slice"))]
                [_source-nominal : unit
                  (if native-source?
                    (if (if (string-eq source-kind "ref")
                      true
                      (if (string-eq source-kind "mut-ref")
                        true
                        (string-eq referent-kind "array")))
                      unit
                      (comptime.comptime-error
                        "typecheck: scalar for native Slice sources must be borrowed"))
                    (if (if (string-eq referent-kind "struct")
                      true
                      (string-eq referent-kind "enum"))
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for source "
                          (comptime.string-append
                            (type-key source-type)
                            " must be a fixed array, borrowed Slice, nominal iterable, or reference to one")))))]
                [module : String
                  (if native-source?
                    ""
                    (type-nominal-module referent-type))]
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
                  (if native-source?
                    source-type
                    (if (comptime.module-value? module constructor-name)
                      (comptime.module-value-type module constructor-name)
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for source "
                          (comptime.string-append
                            (type-key source-type)
                            (comptime.string-append
                              " is missing protocol function "
                              constructor-display))))))]
                [next-type : comptime.Expr
                  (if native-source?
                    source-type
                    (if (comptime.module-value? module next-name)
                      (comptime.module-value-type module next-name)
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for source "
                          (comptime.string-append
                            (type-key source-type)
                            (comptime.string-append
                              " is missing protocol function "
                              next-display))))))]
                [_constructor-callable : unit
                  (if native-source?
                    unit
                    (if (string-eq (type-kind constructor-type) "function")
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for protocol function "
                          (comptime.string-append
                            constructor-display
                            " is not callable")))))]
                [_constructor-arity : unit
                  (if native-source?
                    unit
                    (if (= (function-param-count constructor-type) 1)
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for protocol function "
                          (comptime.string-append
                            constructor-display
                            " must take exactly one source argument")))))]
                [_next-callable : unit
                  (if native-source?
                    unit
                    (if (string-eq (type-kind next-type) "function")
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for protocol function "
                          (comptime.string-append
                            next-display
                            " is not callable")))))]
                [_next-arity : unit
                  (if native-source?
                    unit
                    (if (= (function-param-count next-type) 1)
                      unit
                      (comptime.comptime-error
                        (comptime.string-append
                          "typecheck: for protocol function "
                          (comptime.string-append
                            next-display
                            " must take exactly one iterator argument")))))]
                [next-result : comptime.Expr
                  (if native-source?
                    source-type
                    (function-return-type next-type))]
                [_next-result-enum : unit
                  (if native-source?
                    unit
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
                                " must return a Done/Item enum")))))))]
                [variant-count : i64
                  (if native-source?
                    0
                    (enum-variant-count next-result))]
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
                  (if (if native-source?
                    true
                    (>= done-index 0))
                    unit
                    (comptime.comptime-error
                      (comptime.string-append
                        "typecheck: for protocol result "
                        (comptime.string-append
                          (type-key next-result)
                          " is missing Done"))))
                  (if (if native-source?
                    true
                    (>= item-index 0))
                    unit
                    (comptime.comptime-error
                      (comptime.string-append
                        "typecheck: for protocol result "
                        (comptime.string-append
                          (type-key next-result)
                          " is missing Item"))))
                  (if (if native-source?
                    true
                    (= (enum-variant-payload-count next-result item-index) 1))
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
                [referent-kind : String (type-kind referent-type)]
                [native-source? : bool
                  (if (string-eq referent-kind "array")
                    true
                    (string-eq referent-kind "slice"))]
                [module : String
                  (if native-source?
                    ""
                    (type-nominal-module referent-type))]
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
                  (if native-source?
                    source-type
                    (comptime.module-value-type module next-name))]
                [next-result : comptime.Expr
                  (if native-source?
                    source-type
                    (function-return-type next-type))]
                [variant-count : i64
                  (if native-source?
                    0
                    (enum-variant-count next-result))]
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
                      (if native-source?
                        (array-element-type referent-type)
                        (enum-variant-payload-type next-result item-index 0))]
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
                          (comptime.expr-var (type-cleanup-function item-type))
                          out
                          true)
                        out)]
                    [done-pattern : comptime.Pattern
                      (if native-source?
                        (comptime.pattern-binding "__for_native_unused_done")
                        (comptime.pattern-variant
                          (comptime.string-append
                            (type-nominal-name next-result)
                            ".Done")
                          (comptime.pattern-list-empty)))]
                    [item-pattern : comptime.Pattern
                      (if native-source?
                        payload-pattern
                        (comptime.pattern-variant
                          (comptime.string-append
                            (type-nominal-name next-result)
                            ".Item")
                          (comptime.pattern-list-cons
                            payload-pattern
                            (comptime.pattern-list-empty))))]
                    [iterator-name : String
                      (comptime.syntax-name-fresh
                        (comptime.string-append
                          "__for_iterator_"
                          (comptime.int->string index)))]
                    [iterator-var : comptime.Expr
                      (comptime.expr-var iterator-name)]
                    [next-call : comptime.Expr
                      (if native-source?
                        out
                        (comptime.expr-call
                          (comptime.expr-var next-display)
                          (comptime.expr-list-cons
                            (comptime.expr-mut-borrow iterator-var)
                            (comptime.expr-list-empty))))]
                    [binding-var : comptime.Expr
                      (comptime.expr-var binding-name)]
                    [owned-source-var : comptime.Expr
                      (comptime.expr-var
                        (comptime.syntax-name-fresh
                          (comptime.string-append
                            "__for_owned_source_"
                            (comptime.int->string index))))]
                    [owned-index-var : comptime.Expr
                      (comptime.expr-var
                        (comptime.syntax-name-fresh
                          (comptime.string-append
                            "__for_owned_index_"
                            (comptime.int->string index))))]
                    [view-var : comptime.Expr
                      (comptime.expr-var
                        (comptime.syntax-name-fresh
                          (comptime.string-append
                            "__for_native_view_"
                            (comptime.int->string index))))]
                    [native-length-var : comptime.Expr
                      (comptime.expr-var
                        (comptime.syntax-name-fresh
                          (comptime.string-append
                            "__for_native_length_"
                            (comptime.int->string index))))]
                    [native-index-name : String
                      (comptime.syntax-name-fresh
                        (comptime.string-append
                          "__for_native_index_"
                          (comptime.int->string index)))]
                    [native-index-var : comptime.Expr
                      (comptime.expr-var native-index-name)]
                    [item-init : comptime.Expr
                      (if (string-eq source-kind "mut-ref")
                        (comptime.expr-mut-borrow
                          (comptime.expr-array-ref view-var native-index-var))
                        (comptime.expr-borrow
                          (comptime.expr-array-ref view-var native-index-var)))]
                    (begin
                      (set!
                        out
                        (if native-source?
                          (if (if (string-eq source-kind "ref")
                            true
                            (string-eq source-kind "mut-ref"))
                            (begin
                              (set!
                                out
                                (comptime.expr-begin-unit
                                  (comptime.expr-list-cons
                                    (comptime.expr-set-var
                                      native-index-name
                                      `(+ ,native-index-var 1))
                                    (comptime.expr-list-cons
                                      out
                                      (comptime.expr-list-empty)))))
                              (set!
                                out
                                (if (comptime.expr-binding-clause-has-type?
                                  binding)
                                  (comptime.expr-match
                                    item-init
                                    (comptime.match-arm-list-cons
                                      (comptime.match-arm
                                        (comptime.pattern-binding-typed
                                          binding-name
                                          (comptime.expr-binding-clause-type
                                            binding))
                                        out)
                                      (comptime.match-arm-list-empty)))
                                  (comptime.expr-let-scope
                                    binding-name
                                    item-init
                                    out)))
                              (let
                                [finish : comptime.Expr
                                  (comptime.expr-set-var
                                    done-name
                                    (comptime.expr-bool true))]
                                `(if (< ,native-index-var ,native-length-var)
                                  ,out
                                  ,finish)))
                            (if (comptime.expr-binding-clause-has-type? binding)
                              (comptime.expr-for-owned-step-typed
                                owned-source-var
                                owned-index-var
                                binding-var
                                (comptime.expr-binding-clause-type binding)
                                done-var
                                out)
                              (comptime.expr-for-owned-step
                                owned-source-var
                                owned-index-var
                                binding-var
                                done-var
                                out)))
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
                                (comptime.match-arm-list-empty))))))
                      (set! index (- index 1)))))))
            (let
              [loop-condition : comptime.Expr (comptime.expr-not done-var)]
              (begin
                (set! out (comptime.expr-while loop-condition out))
                (set!
                  out
                  (comptime.expr-let-scope
                    done-name
                    (comptime.expr-bool false)
                    out))))
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
                [referent-kind : String (type-kind referent-type)]
                [native-source? : bool
                  (if (string-eq referent-kind "array")
                    true
                    (string-eq referent-kind "slice"))]
                [module : String
                  (if native-source?
                    ""
                    (type-nominal-module referent-type))]
                [constructor-name : String
                  (if (string-eq source-kind "ref")
                    "iterator"
                    (if (string-eq source-kind "mut-ref")
                      "iterator-mut"
                      "into-iterator"))]
                [constructor-type : comptime.Expr
                  (if native-source?
                    source-type
                    (comptime.module-value-type module constructor-name))]
                [constructor-display : String
                  (if (string-eq module "")
                    constructor-name
                    (comptime.string-append
                      module
                      (comptime.string-append "." constructor-name)))]
                [iterator-type : comptime.Expr
                  (if native-source?
                    source-type
                    (function-return-type constructor-type))]
                [source-temp? : bool
                  (if native-source?
                    false
                    (if (string-eq source-kind "mut-ref")
                      false
                      (not (type-cleanup-owning? source-type))))]
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
                [constructor-call : comptime.Expr
                  (if native-source?
                    source
                    (comptime.expr-call
                      (comptime.expr-var constructor-display)
                      (comptime.expr-list-cons
                        (if source-temp?
                          source-var
                          source)
                        (comptime.expr-list-empty))))]
                [owned-source-var : comptime.Expr
                  (comptime.expr-var
                    (comptime.syntax-name-fresh
                      (comptime.string-append
                        "__for_owned_source_"
                        (comptime.int->string index))))]
                [owned-index-var : comptime.Expr
                  (comptime.expr-var
                    (comptime.syntax-name-fresh
                      (comptime.string-append
                        "__for_owned_index_"
                        (comptime.int->string index))))]
                [native-source-name : String
                  (comptime.syntax-name-fresh
                    (comptime.string-append
                      "__for_native_source_"
                      (comptime.int->string index)))]
                [native-source-var : comptime.Expr
                  (comptime.expr-var native-source-name)]
                [native-length-name : String
                  (comptime.syntax-name-fresh
                    (comptime.string-append
                      "__for_native_length_"
                      (comptime.int->string index)))]
                [native-fixed-length : i64
                  (if (string-eq referent-kind "array")
                    (array-length referent-type)
                    0)]
                [native-fixed-length-init : comptime.Expr
                  `(ann ,(comptime.expr-int native-fixed-length) : i64)]
                [native-slice-length-init : comptime.Expr
                  (comptime.expr-call
                    (comptime.expr-var "array-length")
                    (comptime.expr-list-cons
                      native-source-var
                      (comptime.expr-list-empty)))]
                [native-length-init : comptime.Expr
                  (if (string-eq referent-kind "array")
                    native-fixed-length-init
                    native-slice-length-init)]
                [native-view-name : String
                  (comptime.syntax-name-fresh
                    (comptime.string-append
                      "__for_native_view_"
                      (comptime.int->string index)))]
                [native-index-name : String
                  (comptime.syntax-name-fresh
                    (comptime.string-append
                      "__for_native_index_"
                      (comptime.int->string index)))]
                (begin
                  (set!
                    out
                    (if native-source?
                      (if (if (string-eq source-kind "ref")
                        true
                        (string-eq source-kind "mut-ref"))
                        ;; Build each scope through its own captured `out`
                        ;; update. A single deeply nested builder expression
                        ;; can mix the evaluator's owning pool with the caller
                        ;; syntax pool before the outer call observes the
                        ;; intermediate cursor.
                        (begin
                          (set!
                            out
                            (comptime.expr-let-scope
                              native-index-name
                              `(ann 0 : i64)
                              out))
                          (set!
                            out
                            (comptime.expr-let-scope
                              native-view-name
                              native-source-var
                              out))
                          (set!
                            out
                            (comptime.expr-let-scope
                              native-length-name
                              native-length-init
                              out))
                          (set!
                            out
                            (comptime.expr-let-scope
                              native-source-name
                              source
                              out))
                          out)
                        (comptime.expr-for-owned-state
                          owned-source-var
                          owned-index-var
                          source
                          out))
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
                          out))))
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
                [referent-type : comptime.Expr
                  (if (if (string-eq source-kind "ref")
                    true
                    (string-eq source-kind "mut-ref"))
                    (comptime.reference-element-type source-type)
                    source-type)]
                [referent-kind : String (type-kind referent-type)]
                [native-source? : bool
                  (if (string-eq referent-kind "array")
                    true
                    (string-eq referent-kind "slice"))]
                [source-temp? : bool
                  (if native-source?
                    false
                    (if (string-eq source-kind "mut-ref")
                      false
                      (not (type-cleanup-owning? source-type))))]
                (begin
                  (if source-temp?
                    (let
                      [source-name : String
                        (comptime.syntax-name-fresh
                          (comptime.string-append
                            "__for_source_"
                            (comptime.int->string index)))]
                      (set!
                        out
                        (comptime.expr-let-scope source-name source out)))
                    unit)
                  (set! index (- index 1)))))
            (comptime.expr-begin-unit
              (comptime.expr-list-cons out (comptime.expr-list-empty)))))))))

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