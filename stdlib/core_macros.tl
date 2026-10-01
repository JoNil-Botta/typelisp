;# Core expression macros - the implicit prelude.
;#
;# The compile driver links this module into every program (alongside
;# stdlib/runtime.tl), so a bare `when`, `unless`, `cond`, `and`, `or`, `+=`,
;# `-=`, `for`, `any?`, or `all?` that is not bound locally resolves to these
;# macros without an import. `for` is the scalar iterator loop; it remains
;# distinct from SPMD `foreach`. Local macros and explicit imports shadow the
;# prelude.
;#
;# ```lisp
;# (import stdlib.iterator)
;#
;# (define (main) : i64
;#   (let
;#     [value : i64 0]
;#     [items : (Array i64 2) (array 4 6)]
;#     (begin
;#       (and true true)
;#       (or false true)
;#       (when true (set! value 21))
;#       (unless false (+= value 21))
;#       (for [item (iterator.range 0 0)] (+= value item))
;#       (for [item (& items)] (-= value (deref item)))
;#       (when (any? [item (& items)] (= (deref item) 4)) (+= value 4))
;#       (unless (all? [item (& items)] (> (deref item) 4)) (+= value 6))
;#       (set! value (cond [false 0] [true value] [else value]))
;#       value)))
;# ```
(import stdlib.comptime)

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

;: Add `delta` to the numeric value stored in `place`.
;:
;: `place` is a variable or field path such as `count` or `stats.count`, or
;: any other assignable place such as `(array-ref items (next-index))` or
;: `(deref cell)`. A compound place is borrowed mutably once, so its operands
;: are evaluated exactly once. `delta` is evaluated once, after the place.
(defmacro (+= [place : Expr] [delta : Expr]) : unit
  (match place
    [(comptime.Expr.Var _) `(set! ,place (+ ,place ,delta))]
    [_
      ;; `(set! ,target ...)` assigns through a box place; `(deref ...)`
      ;; reads one.
      (let
        [target : comptime.Expr `(box-get __compound_place)]
        `(let
          [__compound_place (&mut ,place)]
          (set! ,target (+ (deref __compound_place) ,delta))))]))

;: Subtract `delta` from the numeric value stored in `place`.
;:
;: Accepts the same places as `+=` and evaluates each operand exactly once.
(defmacro (-= [place : Expr] [delta : Expr]) : unit
  (match place
    [(comptime.Expr.Var _) `(set! ,place (- ,place ,delta))]
    [_
      ;; `(set! ,target ...)` assigns through a box place; `(deref ...)`
      ;; reads one.
      (let
        [target : comptime.Expr `(box-get __compound_place)]
        `(let
          [__compound_place (&mut ,place)]
          (set! ,target (- (deref __compound_place) ,delta))))]))

;: True when `predicate` holds for some item; stops at the first one.
;:
;: Written `(any? [name source] predicate)` with one unannotated binding
;: clause over any source `for` accepts. An empty source yields false.
(defmacro (any? [bindings : ExprBindingClause ...] [predicate : Expr ...]) : bool
  (let
    [binding-count : i64 (comptime.expr-binding-clause-list-length bindings)]
    [predicate-count : i64 (comptime.expr-list-length predicate)]
    (if (= binding-count 1)
      (if (= predicate-count 1)
        (let
          [binding : comptime.ExprBindingClause
            (comptime.expr-binding-clause-list-nth bindings 0)]
          [item : comptime.Expr
            (comptime.expr-var (comptime.expr-binding-clause-name binding))]
          [source : comptime.Expr (comptime.expr-binding-clause-init binding)]
          [test : comptime.Expr (comptime.expr-list-nth predicate 0)]
          (if (comptime.expr-binding-clause-has-type? binding)
            (comptime.comptime-error
              "typecheck: any? expects one unannotated binding clause [name source] followed by one predicate")
            `(let
              [__any_found false]
              (begin
                (for [,item ,source]
                  (if ,test
                    (begin
                      (set! __any_found true)
                      (break))
                    unit))
                __any_found))))
        (comptime.comptime-error
          "typecheck: any? expects one unannotated binding clause [name source] followed by one predicate"))
      (comptime.comptime-error
        "typecheck: any? expects one unannotated binding clause [name source] followed by one predicate"))))

;: True when `predicate` holds for every item; stops at the first that fails.
;:
;: Written `(all? [name source] predicate)` with one unannotated binding
;: clause over any source `for` accepts. An empty source yields true.
(defmacro (all? [bindings : ExprBindingClause ...] [predicate : Expr ...]) : bool
  (let
    [binding-count : i64 (comptime.expr-binding-clause-list-length bindings)]
    [predicate-count : i64 (comptime.expr-list-length predicate)]
    (if (= binding-count 1)
      (if (= predicate-count 1)
        (let
          [binding : comptime.ExprBindingClause
            (comptime.expr-binding-clause-list-nth bindings 0)]
          [item : comptime.Expr
            (comptime.expr-var (comptime.expr-binding-clause-name binding))]
          [source : comptime.Expr (comptime.expr-binding-clause-init binding)]
          [test : comptime.Expr (comptime.expr-list-nth predicate 0)]
          (if (comptime.expr-binding-clause-has-type? binding)
            (comptime.comptime-error
              "typecheck: all? expects one unannotated binding clause [name source] followed by one predicate")
            `(let
              [__all_hold true]
              (begin
                (for [,item ,source]
                  (if ,test
                    unit
                    (begin
                      (set! __all_hold false)
                      (break))))
                __all_hold))))
        (comptime.comptime-error
          "typecheck: all? expects one unannotated binding clause [name source] followed by one predicate"))
      (comptime.comptime-error
        "typecheck: all? expects one unannotated binding clause [name source] followed by one predicate"))))

;: Traverse one or more scalar iterables with zip-shortest semantics.
;:
;: Leading operands are let-like clauses, `[name source]` or
;: `[name : ItemType source]`, followed by one or more unit-valued body
;: expressions. Every source is evaluated once and every iterator state is
;: constructed once.
;:
;: A fixed array, or a borrowed Slice or `__tl_dyn-array`, is walked by index:
;: a borrowed source yields `&` / `&mut` element references and an owned fixed
;: array yields its elements. A borrowed struct whose first two fields are
;: `slots : (__tl_dyn-array T)` and `len : i64`, and whose module defines no
;: `iterator` / `iterator-mut`, is walked the same way over its first `len`
;: slots, so `(for [x (& seq)] ...)` borrows each element without cloning.
;: Any other source uses its defining module's protocol: a shared source
;: selects `iterator` / `next`, a mutable source selects `iterator-mut` /
;: `next-mut`, and an owned source selects `into-iterator` / `into-next`.
;: A single unannotated clause whose source is a direct call of
;: `stdlib.iterator`'s `range` (spelled `range` or `alias.range`) counts from
;: its first bound to its second, evaluating each bound once, without
;: constructing the range.
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
        ;; A single unannotated clause over a counted range or an indexable
        ;; borrow expands to one index-driven `while`: no iterator state, done
        ;; flag, or protocol call per item. `lean-shape` is 0 for everything
        ;; else, which takes the general path below; 1 is a borrowed fixed
        ;; array, 2 a borrowed Slice or `__tl_dyn-array`, 3 a borrowed
        ;; slots/len struct and 4 a direct `range` call.
        (let
          [lean-binding : comptime.ExprBindingClause
            (comptime.expr-binding-clause-list-nth bindings 0)]
          [lean-source : comptime.Expr
            (comptime.expr-binding-clause-init lean-binding)]
          [lean-type : comptime.Expr (comptime.expr-type lean-source)]
          [lean-kind : String (type-kind lean-type)]
          [lean-mut? : bool (string-eq lean-kind "mut-ref")]
          [lean-borrowed? : bool
            (if lean-mut?
              true
              (string-eq lean-kind "ref"))]
          [lean-referent : comptime.Expr
            (if lean-borrowed?
              (comptime.reference-element-type lean-type)
              lean-type)]
          [lean-referent-kind : String (type-kind lean-referent)]
          [lean-candidate? : bool
            (if (= binding-count 1)
              (if (comptime.expr-binding-clause-has-type? lean-binding)
                false
                true)
              false)]
          ;; A struct whose module defines the protocol keeps the protocol.
          [lean-struct-kind? : bool
            (if lean-candidate?
              (if lean-borrowed?
                (string-eq lean-referent-kind "struct")
                false)
              false)]
          [lean-module : String
            (if lean-struct-kind?
              (type-nominal-module lean-referent)
              "")]
          [lean-protocol : String
            (if lean-mut?
              "iterator-mut"
              "iterator")]
          [lean-struct? : bool
            (if lean-struct-kind?
              (if (comptime.module-value? lean-module lean-protocol)
                false
                true)
              false)]
          [lean-range-type? : bool
            (if lean-candidate?
              (if (string-eq lean-kind "struct")
                (if (string-eq
                  (type-nominal-module lean-type)
                  "stdlib.iterator")
                  (string-eq (type-nominal-name lean-type) "I64Range")
                  false)
                false)
              false)]
          ;; A slots/len struct starts with `slots : (__tl_dyn-array T)` and
          ;; `len : i64`; a struct with an offset field between them is not one.
          [slots-first? : bool
            (if lean-struct?
              (if (>= (struct-field-count lean-referent) 2)
                (if (string-eq (struct-field-name lean-referent 0) "slots")
                  (string-eq
                    (type-kind (struct-field-type lean-referent 0))
                    "dyn-array")
                  false)
                false)
              false)]
          [len-second? : bool
            (if slots-first?
              (if (string-eq (struct-field-name lean-referent 1) "len")
                (string-eq
                  (type-kind (struct-field-type lean-referent 1))
                  "i64")
                false)
              false)]
          ;; The two bounds of a direct `range` / `alias.range` call, or empty.
          [range-args : comptime.ExprList
            (if lean-range-type?
              (match lean-source
                [(comptime.Expr.Call callee args)
                  (match callee
                    [(comptime.Expr.Var name)
                      (let
                        [name-length : i64 (__tl_string_length name)]
                        (if (string-eq name "range")
                          args
                          (if (> name-length 6)
                            (if (string-eq
                              (comptime.string-slice name (- name-length 6) 6)
                              ".range")
                              args
                              (comptime.expr-list-empty))
                            (comptime.expr-list-empty))))]
                    [_ (comptime.expr-list-empty)])]
                [_ (comptime.expr-list-empty)])
              (comptime.expr-list-empty))]
          [range-call? : bool (= (comptime.expr-list-length range-args) 2)]
          [lean-shape : i64
            (if range-call?
              4
              (if lean-candidate?
                (if lean-borrowed?
                  ;; Macro CTFE runs before `cond` is available.
                  ;; lint-allow: nested-if-ladder
                  (if (string-eq lean-referent-kind "array")
                    1
                    (if (string-eq lean-referent-kind "slice")
                      2
                      (if (string-eq lean-referent-kind "dyn-array")
                        2
                        (if len-second?
                          3
                          0))))
                  0)
                0))]
          (if (= lean-shape 0)
            (let
              [done-name : String (comptime.syntax-name-fresh "__for_done_0")]
              [done-var : comptime.Expr (comptime.expr-var done-name)]
              [out : comptime.Expr (comptime.expr-begin-unit body)]
              ;; One letter per clause: N indexable, S slots/len struct, P protocol.
              [plan : String ""]
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
                    [borrowed? : bool
                      (if (string-eq source-kind "ref")
                        true
                        (string-eq source-kind "mut-ref"))]
                    [array-source? : bool
                      (if (string-eq referent-kind "array")
                        true
                        (if (string-eq referent-kind "slice")
                          true
                          (string-eq referent-kind "dyn-array")))]
                    [_source-nominal : unit
                      (if array-source?
                        (if (if borrowed?
                          true
                          (string-eq referent-kind "array"))
                          unit
                          (comptime.comptime-error
                            "typecheck: scalar for Slice and __tl_dyn-array sources must be borrowed: write (& source) or (&mut source)"))
                        (if (if (string-eq referent-kind "struct")
                          true
                          (string-eq referent-kind "enum"))
                          unit
                          (comptime.comptime-error
                            (comptime.string-append
                              "typecheck: for source "
                              (comptime.string-append
                                (type-key source-type)
                                " must be a fixed array, borrowed Slice or __tl_dyn-array, borrowed slots/len struct, nominal iterable, or reference to one")))))]
                    [module : String
                      (if array-source?
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
                    ;; A borrowed struct that starts with `slots :
                    ;; (__tl_dyn-array T)` and `len : i64` is walked by index
                    ;; like a borrowed array, unless its module defines the
                    ;; protocol.
                    [slots-candidate? : bool
                      (if array-source?
                        false
                        (if borrowed?
                          (if (string-eq referent-kind "struct")
                            (if (comptime.module-value? module constructor-name)
                              false
                              true)
                            false)
                          false))]
                    [slots-first? : bool
                      (if slots-candidate?
                        (if (>= (struct-field-count referent-type) 2)
                          (if (string-eq
                            (struct-field-name referent-type 0)
                            "slots")
                            (string-eq
                              (type-kind (struct-field-type referent-type 0))
                              "dyn-array")
                            false)
                          false)
                        false)]
                    [slots-source? : bool
                      (if slots-first?
                        (if (string-eq
                          (struct-field-name referent-type 1)
                          "len")
                          (string-eq
                            (type-kind (struct-field-type referent-type 1))
                            "i64")
                          false)
                        false)]
                    [native-source? : bool
                      (if array-source?
                        true
                        slots-source?)]
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
                        (=
                          (enum-variant-payload-count next-result item-index)
                          1))
                        unit
                        (comptime.comptime-error
                          "typecheck: for protocol Item must carry exactly one item"))
                      (set!
                        plan
                        (comptime.string-append
                          (if slots-source?
                            "S"
                            (if native-source?
                              "N"
                              "P"))
                          plan))
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
                    [shape : String (comptime.string-slice plan index 1)]
                    [native-source? : bool
                      (if (string-eq shape "P")
                        false
                        true)]
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
                            referent-type
                            (enum-variant-payload-type next-result item-index 0))]
                        [item-cleanup? : bool
                          (if native-source?
                            false
                            (type-cleanup-owning? item-type))]
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
                          (if native-source?
                            (comptime.pattern-binding
                              "__for_native_unused_done")
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
                              (comptime.expr-array-ref
                                view-var
                                native-index-var))
                            (comptime.expr-borrow
                              (comptime.expr-array-ref
                                view-var
                                native-index-var)))]
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
                                    `(if (<
                                      ,native-index-var
                                      ,native-length-var)
                                      ,out
                                      ,finish)))
                                (if (comptime.expr-binding-clause-has-type?
                                  binding)
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
                    [shape : String (comptime.string-slice plan index 1)]
                    [native-source? : bool
                      (if (string-eq shape "P")
                        false
                        true)]
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
                      (if (string-eq shape "S")
                        (comptime.expr-struct-get `,native-source-var "len")
                        (if (string-eq referent-kind "array")
                          native-fixed-length-init
                          native-slice-length-init))]
                    [native-view-init : comptime.Expr
                      (if (string-eq shape "S")
                        (if (string-eq source-kind "mut-ref")
                          (comptime.expr-mut-borrow
                            (comptime.expr-struct-get
                              `,native-source-var
                              "slots"))
                          (comptime.expr-borrow
                            (comptime.expr-struct-get
                              `,native-source-var
                              "slots")))
                        native-source-var)]
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
                                  native-view-init
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
                    [protocol-source? : bool
                      (string-eq (comptime.string-slice plan index 1) "P")]
                    [source-type : comptime.Expr
                      (if protocol-source?
                        (comptime.expr-type source)
                        source)]
                    [source-temp? : bool
                      (if protocol-source?
                        (if (string-eq (type-kind source-type) "mut-ref")
                          false
                          (not (type-cleanup-owning? source-type)))
                        false)]
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
                  (comptime.expr-list-cons out (comptime.expr-list-empty)))))
            (let
              [item-name : String
                (comptime.expr-binding-clause-name lean-binding)]
              [view : comptime.Expr
                (if (= lean-shape 3)
                  (comptime.expr-struct-get `__for_source "slots")
                  `__for_source)]
              [item-init : comptime.Expr
                (if (= lean-shape 4)
                  `__for_index
                  (if lean-mut?
                    `(&mut (array-ref ,view __for_index))
                    `(& (array-ref ,view __for_index))))]
              ;; Advance before the body so `continue` moves to the next item.
              [step-body : comptime.Expr
                `(begin
                  (set! __for_index (+ __for_index 1))
                  ,@body
                  unit)]
              [step : comptime.Expr
                (comptime.expr-let-scope item-name item-init step-body)]
              [fixed-length : i64
                (if (= lean-shape 1)
                  (array-length lean-referent)
                  0)]
              [length-init : comptime.Expr
                (if (= lean-shape 1)
                  `(ann ,(comptime.expr-int fixed-length) : i64)
                  (if (= lean-shape 3)
                    (comptime.expr-struct-get `__for_source "len")
                    `(array-length __for_source)))]
              (if (= lean-shape 4)
                (let
                  [range-start : comptime.Expr
                    (comptime.expr-list-nth range-args 0)]
                  [range-end : comptime.Expr
                    (comptime.expr-list-nth range-args 1)]
                  `(let
                    [__for_index (ann ,range-start : i64)]
                    [__for_end (ann ,range-end : i64)]
                    (while (< __for_index __for_end)
                      ,step)))
                `(let
                  [__for_source ,lean-source]
                  [__for_length ,length-init]
                  [__for_index (ann 0 : i64)]
                  (while (< __for_index __for_length)
                    ,step))))))))))

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