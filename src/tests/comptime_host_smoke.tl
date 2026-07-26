;; comptime_host_smoke.tl - Compiler-owned native-comptime host session smoke.
;;
;; Drives the callback-invoke dispatcher directly through the operation
;; sequence a natively compiled `(f ,x)` quasiquote body will emit, and
;; asserts the committed result is the same AST shape the interpreted
;; builders produce. It also checks macro-call provenance, fold hygiene-marker
;; parity, and the status contract for stale cookies, empty-stack and duplicate
;; commits, unknown operations, and fuel exhaustion. Refs #5212, #5475, #5503,
;; #4870.
(import "../compiler_embedded_stdlib_tlci.tl")
(import "../tlci_core.tl")
(import "../tlci_loader.tl")
(import "../compiler_ast_types.tl")
(import "../compiler_ctfe.tl")
(import compiler_intern as ci)
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)

(define comptime-host-smoke-cookie : i64
  0x5151)

(define (comptime-host-smoke-name-ptr [name : String]) : i64
  (cast
    (unsafe
      (ptr->int (string-data name)))
    : i64))

(define (comptime-host-smoke-invoke [operation : i64] [a : i64] [b : i64]) : i64
  (compiler-comptime-host-invoke comptime-host-smoke-cookie operation a b 0))

;; Build `(f ,x)` through the dispatcher: callee var, empty list, operand
;; push, append, call, commit.
(define (comptime-host-smoke-construct-ok?) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operand-node : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "x")))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    [callee-name : String "__tl_array-length"]
    (begin
      (array-set!
        operands
        0
        (CompilerCtfeValue.Expr operand-node (AstType.Expr)))
      (compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (ctfe-reflect-info-list-empty))
      (and
        (= (comptime-host-smoke-invoke tlci-host-callback-op-fuel-check 0 0) 0)
        (=
          (comptime-host-smoke-invoke
            tlci-host-callback-op-expr-var
            (comptime-host-smoke-name-ptr callee-name)
            (string.string-length callee-name))
          0)
        (=
          (comptime-host-smoke-invoke tlci-host-callback-op-expr-list-empty 0 0)
          0)
        (=
          (comptime-host-smoke-invoke tlci-host-callback-op-push-operand 0 0)
          0)
        (=
          (comptime-host-smoke-invoke
            tlci-host-callback-op-expr-list-append
            0
            0)
          0)
        (= (comptime-host-smoke-invoke tlci-host-callback-op-expr-call 0 0) 0)
        (=
          (comptime-host-smoke-invoke tlci-host-callback-op-commit-result 0 0)
          0)
        (compiler-comptime-host-result-ready?)
        (comptime-host-smoke-result-shape-ok? pools operand-node)))))

(define (comptime-host-smoke-result-shape-ok?
  [pools : AstNodePoolContext]
  [operand-node : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Call callee-id args)
          (and
            (match (ast-node-pool-context-expr-get pools callee-id)
              [(AstExpr.Var name-id)
                (=
                  name-id
                  (ci.intern-template-source-id (ci.intern "__tl_array-length")))]
              [_ false])
            (= (ast-expr-list-len (& args)) 1)
            (= (ast-expr-list-get (& args) 0 -1) operand-node))]
        [_ false])]
    [_ false]))

(define (comptime-host-smoke-result-is-hygiene-free?) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (= node (ctfe-result-hygiene-free-node-id))]
    [_ false]))

;; Reflection probes return 1/0 as data rather than callback statuses. A true
;; result must not poison the following construction operation, and the
;; malformed-request sentinel is likewise caller-owned until a native entry
;; translates it to the public bad-request status.
(define (comptime-host-smoke-type-kind-data-ok?) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    [i64-kind : String "i64"]
    [string-kind : String "string"]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Type (AstType.I64)))
      (compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (ctfe-reflect-info-list-empty))
      (let
        [matched : i64
          (compiler-comptime-host-invoke
            comptime-host-smoke-cookie
            tlci-host-callback-op-operand-type-kind-eq
            0
            (comptime-host-smoke-name-ptr i64-kind)
            (string.string-length i64-kind))]
        [mismatched : i64
          (compiler-comptime-host-invoke
            comptime-host-smoke-cookie
            tlci-host-callback-op-operand-type-kind-eq
            0
            (comptime-host-smoke-name-ptr string-kind)
            (string.string-length string-kind))]
        [malformed : i64
          (compiler-comptime-host-invoke
            comptime-host-smoke-cookie
            tlci-host-callback-op-operand-type-kind-eq
            1
            (comptime-host-smoke-name-ptr i64-kind)
            (string.string-length i64-kind))]
        [after-data : i64
          (comptime-host-smoke-invoke
            tlci-host-callback-op-expr-bool-literal
            1
            0)]
        [ok : bool
          (and
            (= matched 1)
            (= mismatched 0)
            (< malformed 0)
            (= after-data tlci-host-callback-status-ok))]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; Reflection result callbacks and their computed expression/pattern consumers
;; are the shared host surface used by the eight eq/hash fold bodies in #5626.
;; Keep a compact nominal metadata table here so this test exercises the
;; callback contract independently of the embedded-stdlib coverage census.
(define (comptime-host-smoke-reflections [pools : AstNodePoolContext]) : CtfeReflectInfoList
  (let
    [pair-id : i64 (ci.intern "HostSmokePair")]
    [choice-id : i64 (ci.intern "HostSmokeChoice")]
    [fields : CtfeReflectFieldList (ctfe-reflect-field-list-with-capacity 2)]
    [payloads : AstTypeList (ast-type-list-with-capacity 2)]
    [variants : CtfeReflectVariantList
      (ctfe-reflect-variant-list-with-capacity 2)]
    [infos : CtfeReflectInfoList (ctfe-reflect-info-list-with-capacity 2)]
    (begin
      (set!
        fields
        (ctfe-reflect-field-list-push
          fields
          (CtfeReflectField.Field (ci.intern "alpha") (AstType.I64))))
      (set!
        fields
        (ctfe-reflect-field-list-push
          fields
          (CtfeReflectField.Field (ci.intern "beta") (AstType.Bool))))
      (ast-type-list-push
        (&mut payloads)
        (ast-node-pool-context-type-push pools (AstType.I64)))
      (ast-type-list-push
        (&mut payloads)
        (ast-node-pool-context-type-push pools (AstType.Bool)))
      (set!
        variants
        (ctfe-reflect-variant-list-push
          variants
          (CtfeReflectVariant.Variant (ci.intern "Some") payloads)))
      (set!
        variants
        (ctfe-reflect-variant-list-push
          variants
          (CtfeReflectVariant.Variant (ci.intern "None") (ast-type-list-new))))
      (set!
        infos
        (ctfe-reflect-info-list-push-id
          infos
          (CtfeReflectInfo.Struct
            "HostSmokePair"
            ""
            "HostSmokePair"
            pair-id
            (CtfeReflectCleanup.No)
            fields)
          pair-id))
      (ctfe-reflect-info-list-push-id
        infos
        (CtfeReflectInfo.Enum
          "HostSmokeChoice"
          ""
          "HostSmokeChoice"
          choice-id
          (CtfeReflectCleanup.No)
          variants)
        choice-id))))

(define (comptime-host-smoke-commit-result!) : bool
  (=
    (comptime-host-smoke-invoke tlci-host-callback-op-commit-result 0 0)
    tlci-host-callback-status-ok))

;; The reflection builder test below batches several independent logical
;; invocations under one expensive metadata setup. Consume its synthetic result
;; between probes; real macro entries never receive this reset capability.
(define (comptime-host-smoke-consume-test-result!) : bool
  (begin
    (set! compiler-comptime-host-result-ready false)
    true))

(define (comptime-host-smoke-result-name? [expected : String]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Name text _) (string.eq text expected)]
    [(CompilerCtfeValue.String text _) (string.eq text expected)]
    [_ false]))

(define (comptime-host-smoke-result-type? [expected-bool : bool]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Type ty)
      (if expected-bool
        (match ty
          [(AstType.Bool) true]
          [_ false])
        (match ty
          [(AstType.I64) true]
          [_ false]))]
    [_ false]))

(define (comptime-host-smoke-result-struct-get?
  [pools : AstNodePoolContext]
  [target : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.StructGet actual field)
          (and (= actual target) (string.eq (intern-str field) "alpha"))]
        [_ false])]
    [_ false]))

(define (comptime-host-smoke-result-tuple-ref?
  [pools : AstNodePoolContext]
  [target : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.TupleRef actual index) (and (= actual target) (= index 1))]
        [_ false])]
    [_ false]))

(define (comptime-host-smoke-result-reflected-match?
  [pools : AstNodePoolContext]
  [scrutinee : i64]
  [body : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Match match-box)
          (match (box-get match-box)
            [(AstMatch.Match actual arms)
              (and
                (= actual scrutinee)
                (= (struct-get arms len) 1)
                (match (array-ref (struct-get arms slots) 0)
                  [(AstMatchArm.Arm pattern actual-body)
                    (and
                      (= actual-body body)
                      (match pattern
                        [(AstPattern.Variant name args-box)
                          (let
                            [args : AstPatternList (box-get args-box)]
                            (and
                              (string.eq (intern-str name) "Some")
                              (= (struct-get (& args) len) 2)
                              (match (array-ref (struct-get (& args) slots) 0)
                                [(AstPattern.Binding first)
                                  (string.eq (intern-str first) "p0")]
                                [_ false])
                              (match (array-ref (struct-get (& args) slots) 1)
                                [(AstPattern.Binding second)
                                  (string.eq (intern-str second) "p1")]
                                [_ false])))]
                        [_ false]))]
                  [_ false]))]
            [_ false])]
        [_ false])]
    [_ false]))

(define (comptime-host-smoke-reflection-builders-ok?) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [pair-id : i64 (ci.intern "HostSmokePair")]
    [choice-id : i64 (ci.intern "HostSmokeChoice")]
    [tuple-items : AstTypeList (ast-type-list-with-capacity 2)]
    [value-node : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "value")))]
    [body-node : i64
      (ast-node-pool-context-expr-push
        pools
        (AstExpr.Literal (AstLiteral.Bool true)))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 5)]
    [prefix : String "p"]
    (begin
      (ast-type-list-push
        (&mut tuple-items)
        (ast-node-pool-context-type-push pools (AstType.I64)))
      (ast-type-list-push
        (&mut tuple-items)
        (ast-node-pool-context-type-push pools (AstType.Bool)))
      (array-set! operands 0 (CompilerCtfeValue.Type (AstType.Struct pair-id)))
      (array-set! operands 1 (CompilerCtfeValue.Type (AstType.Enum choice-id)))
      (array-set!
        operands
        2
        (CompilerCtfeValue.Type (AstType.Tuple (box tuple-items))))
      (array-set! operands 3 (CompilerCtfeValue.Expr value-node (AstType.Expr)))
      (array-set! operands 4 (CompilerCtfeValue.Expr body-node (AstType.Bool)))
      (compiler-comptime-host-session-open!
        pools
        operands
        5
        64
        comptime-host-smoke-cookie
        (comptime-host-smoke-reflections pools))
      (let
        [ok : bool
          (and
            ;; Count callbacks return data and consume their pushed type.
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-struct-field-count
                0
                0)
              2)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                2
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-tuple-element-count
                0
                0)
              2)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-enum-variant-count
                0
                0)
              2)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-enum-variant-payload-count
                0
                0)
              2)
            ;; Name and type queries preserve the same values as interpreted
            ;; reflection.
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-struct-field-name
                1
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-name? "beta")
            (comptime-host-smoke-consume-test-result!)
            ;; Interpreted String arguments accept reflected Name values too:
            ;; this exact `"." + field-name` shape is used by struct hashing.
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-string-value
                (comptime-host-smoke-name-ptr ".")
                1)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-struct-field-name
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-string-append
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-name? ".alpha")
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-struct-field-type
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-type? false)
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                2
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-tuple-element-type
                1
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-type? true)
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-enum-variant-name
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-name? "Some")
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-enum-variant-payload-type
                0
                1)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-type? true)
            (comptime-host-smoke-consume-test-result!)
            ;; Dynamic projections consume reflected names/indexes.
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                3
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-struct-field-name
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-expr-struct-get-from-value
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-struct-get? pools value-node)
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                3
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-expr-tuple-ref
                1
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-tuple-ref? pools value-node)
            (comptime-host-smoke-consume-test-result!)
            ;; Assemble a variant match from a reflected name and dense
            ;; generated payload bindings.
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                3
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-enum-variant-name
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-string-value
                (comptime-host-smoke-name-ptr prefix)
                (string.string-length prefix))
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-pattern-list-bindings
                2
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-pattern-variant-from-value
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-push-operand
                4
                0)
              0)
            (=
              (comptime-host-smoke-invoke tlci-host-callback-op-match-arm 0 0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-match-arm-list-empty
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-match-arm-list-cons-from-values
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke tlci-host-callback-op-expr-match 0 0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-reflected-match?
              pools
              value-node
              body-node))]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; Dense binding construction charges one unit per generated payload binding
;; and rejects the request before allocating when the shared session budget is
;; too small.
(define (comptime-host-smoke-pattern-binding-fuel-ok?) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    [prefix : String "p"]
    (begin
      (compiler-comptime-host-session-open!
        pools
        operands
        0
        1
        comptime-host-smoke-cookie
        (ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (and
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-string-value
                (comptime-host-smoke-name-ptr prefix)
                (string.string-length prefix))
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-pattern-list-bindings
                2
                0)
              tlci-host-callback-status-fuel-exhausted))]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; Native sequence folds must publish the same exact-root hygiene exemption as
;; their interpreted CTFE counterparts. Otherwise a later handoff clones and
;; reattributes captured caller syntax through the macro definition context.
(define (comptime-host-smoke-expr-list-fold-hygiene-ok?) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [condition-node : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "flag")))]
    [items : AstExprList (ast-expr-cons condition-node (ast-expr-list-new))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.ExprList items))
      (ctfe-result-hygiene-free-reset!)
      (compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (and
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-expr-bool-literal
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-expr-bool-literal
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-expr-list-fold-if
                0
                1)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-commit-result
                0
                0)
              0)
            (comptime-host-smoke-result-is-hygiene-free?))]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

(define (comptime-host-smoke-clause-list-fold-hygiene-ok?) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [condition-node : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "flag")))]
    [result-node : i64
      (ast-node-pool-context-expr-push
        pools
        (AstExpr.Literal (AstLiteral.Bool true)))]
    [else-node : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "else")))]
    [clauses : AstExprClauseList (ast-expr-clause-list-new)]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (ast-expr-clause-list-push
        (&mut clauses)
        (ast-expr-clause condition-node result-node))
      (ast-expr-clause-list-push
        (&mut clauses)
        (ast-expr-clause else-node result-node))
      (array-set! operands 0 (CompilerCtfeValue.ExprClauseList clauses))
      (ctfe-result-hygiene-free-reset!)
      (compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (and
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-expr-bool-literal
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-expr-bool-literal
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-expr-clause-list-fold-if
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-commit-result
                0
                0)
              0)
            (comptime-host-smoke-result-is-hygiene-free?))]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

(define (comptime-host-smoke-call-provenance-ok?) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    [macro-name : String "nested-macro"]
    [macro-name-id : i64 (ci.intern macro-name)]
    (begin
      (ctfe-visible-macro-names-reset!)
      (ctfe-visible-macro-name-add! macro-name-id)
      (ctfe-result-macro-provenance-reset!)
      (compiler-comptime-host-session-open!
        pools
        operands
        0
        8
        comptime-host-smoke-cookie
        (ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (and
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-expr-var
                (comptime-host-smoke-name-ptr macro-name)
                (string.string-length macro-name))
              0)
            (=
              (comptime-host-smoke-invoke
                tlci-host-callback-op-expr-list-empty
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke tlci-host-callback-op-expr-call 0 0)
              0)
            (ctfe-result-may-contain-macro?))]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; One invocation owns one public result slot. A buggy native entry must not
;; overwrite its first committed handle; the second commit is a bad request,
;; leaves the first value intact, and poisons the remainder of the session.
(define (comptime-host-smoke-single-commit-ok?) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Bool true))
      (compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (ctfe-reflect-info-list-empty))
      (let
        [first-push : i64
          (comptime-host-smoke-invoke tlci-host-callback-op-push-operand 0 0)]
        [first-commit : i64
          (comptime-host-smoke-invoke tlci-host-callback-op-commit-result 0 0)]
        [second-push : i64
          (comptime-host-smoke-invoke
            tlci-host-callback-op-expr-bool-literal
            0
            0)]
        [second-commit : i64
          (comptime-host-smoke-invoke tlci-host-callback-op-commit-result 0 0)]
        [first-result-kept : bool
          (match (compiler-comptime-host-result-value)
            [(CompilerCtfeValue.Bool flag) flag]
            [_ false])]
        [latched : i64
          (comptime-host-smoke-invoke
            tlci-host-callback-op-expr-unit-literal
            0
            0)]
        [ok : bool
          (and
            (= first-push tlci-host-callback-status-ok)
            (= first-commit tlci-host-callback-status-ok)
            (= second-push tlci-host-callback-status-ok)
            (= second-commit tlci-host-callback-status-bad-request)
            first-result-kept
            (= latched tlci-host-callback-status-bad-request))]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; Statuses: stale cookie, empty-stack commit, unknown operation, and fuel
;; exhaustion all answer without committing state.
(define (comptime-host-smoke-status-ok?) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (compiler-comptime-host-session-open!
        pools
        operands
        0
        1
        comptime-host-smoke-cookie
        (ctfe-reflect-info-list-empty))
      (and
        (=
          (compiler-comptime-host-invoke
            0x9999
            tlci-host-callback-op-expr-list-empty
            0
            0
            0)
          tlci-host-callback-status-bad-request)
        (=
          (comptime-host-smoke-invoke tlci-host-callback-op-commit-result 0 0)
          tlci-host-callback-status-bad-request)
        (=
          (comptime-host-smoke-invoke 9999 0 0)
          tlci-host-callback-status-bad-request)
        (=
          (comptime-host-smoke-invoke tlci-host-callback-op-fuel-check 0 0)
          tlci-host-callback-status-bad-request)
        (begin
          (compiler-comptime-host-session-close!)
          (compiler-comptime-host-session-open!
            pools
            operands
            0
            1
            comptime-host-smoke-cookie
            (ctfe-reflect-info-list-empty))
          true)
        (= (comptime-host-smoke-invoke tlci-host-callback-op-fuel-check 0 0) 0)
        (=
          (comptime-host-smoke-invoke tlci-host-callback-op-fuel-check 0 0)
          tlci-host-callback-status-fuel-exhausted)
        (=
          (comptime-host-smoke-invoke tlci-host-callback-op-expr-list-empty 0 0)
          tlci-host-callback-status-fuel-exhausted)
        (not (compiler-comptime-host-result-ready?))))))

(define (comptime-host-smoke-closed-session-ok?) : bool
  (begin
    (compiler-comptime-host-session-close!)
    (=
      (comptime-host-smoke-invoke tlci-host-callback-op-expr-list-empty 0 0)
      tlci-host-callback-status-bad-request)))

(define (comptime-host-smoke-table-ok?) : bool
  (match (tlci-validate-host-callback-table (compiler-comptime-host-table))
    [(ResultTlciHostAbi.Ok) true]
    [(ResultTlciHostAbi.Err _) false]))

(define (main) : i64
  (cond
    [(not (comptime-host-smoke-construct-ok?))
      (io.panic "comptime host smoke: construction")]
    [(not (comptime-host-smoke-type-kind-data-ok?))
      (io.panic "comptime host smoke: type-kind data status")]
    [(not (comptime-host-smoke-reflection-builders-ok?))
      (io.panic "comptime host smoke: reflection builders")]
    [(not (comptime-host-smoke-pattern-binding-fuel-ok?))
      (io.panic "comptime host smoke: pattern binding fuel")]
    [(not (comptime-host-smoke-expr-list-fold-hygiene-ok?))
      (io.panic "comptime host smoke: expression fold hygiene")]
    [(not (comptime-host-smoke-clause-list-fold-hygiene-ok?))
      (io.panic "comptime host smoke: clause fold hygiene")]
    [(not (comptime-host-smoke-call-provenance-ok?))
      (io.panic "comptime host smoke: call provenance")]
    [(not (comptime-host-smoke-single-commit-ok?))
      (io.panic "comptime host smoke: single result commit")]
    [(not (comptime-host-smoke-status-ok?))
      (io.panic "comptime host smoke: status contract")]
    [(not (comptime-host-smoke-closed-session-ok?))
      (io.panic "comptime host smoke: closed session")]
    [(not (comptime-host-smoke-table-ok?))
      (io.panic "comptime host smoke: host table")]
    [else 42]))