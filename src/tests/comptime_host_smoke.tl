;; comptime_host_smoke.tl - Compiler-owned native-comptime host session smoke.
;;
;; Drives the named host callbacks directly through the sequence a natively
;; compiled `(f ,x)` quasiquote body will emit, and
;; asserts the committed result is the same AST shape the interpreted
;; builders produce. It also checks macro-call provenance, fold hygiene-marker
;; parity, and the status contract for stale cookies, empty-stack and duplicate
;; commits, fuel exhaustion, and native panic/abort without partial commit.
;; Refs #5212, #5475, #5503, #4870, #6609.
(import compiler_embedded_stdlib_tlci)
(import tlci_core)
(import compiler_ast_types)
(import compiler_ctfe)
(import compiler_intern as ci)
(import stdlib.io)
(import stdlib.string)

(define comptime-host-smoke-cookie : i64
  0x5151)

(define (comptime-host-smoke-name-ptr [name : String]) : i64
  (cast
    (unsafe
      (ptr->int (string-data name)))
    : i64))

(define (comptime-host-smoke-invoke
  [callback : (-> i64 i64 i64 i64 i64)]
  [a : i64]
  [b : i64]) : i64
  (callback comptime-host-smoke-cookie a b 0))

;; Build `(f ,x)` through named callbacks: callee var, empty list, operand
;; push, append, call, commit.
(define (comptime-host-smoke-construct-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operand-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "x")))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    [callee-name : String "__tl_array-length"]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr
          operand-node
          (compiler_ast_types.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (and
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-fuel-check
            0
            0)
          0)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-var
            (comptime-host-smoke-name-ptr callee-name)
            (string.string-length callee-name))
          0)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-list-empty
            0
            0)
          0)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
            0
            0)
          0)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-list-append
            0
            0)
          0)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-call
            0
            0)
          0)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
            0
            0)
          0)
        (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
        (comptime-host-smoke-result-shape-ok? pools operand-node)))))

(define (comptime-host-smoke-result-shape-ok?
  [pools : compiler_ast_types.AstNodePoolContext]
  [operand-node : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (compiler_ast_types.ast-node-pool-context-expr-get pools node)
        [(compiler_ast_types.AstExpr.Call callee-id args)
          (and
            (match (compiler_ast_types.ast-node-pool-context-expr-get
              pools
              callee-id)
              [(compiler_ast_types.AstExpr.Var name-id)
                (=
                  name-id
                  (ci.intern-template-source-id (ci.intern "__tl_array-length")))]
              [_ false])
            (= (compiler_ast_types.ast-expr-list-len (& args)) 1)
            (=
              (compiler_ast_types.ast-expr-list-get (& args) 0 -1)
              operand-node))]
        [_ false])]
    [_ false]))

(define (comptime-host-smoke-result-is-hygiene-free?) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (= node (compiler_ctfe.ctfe-result-hygiene-free-node-id))]
    [_ false]))

;; Reflection probes return 1/0 as data rather than callback statuses. A true
;; result must not poison the following construction operation, and the
;; malformed-request sentinel is likewise caller-owned until a native entry
;; translates it to the public bad-request status.
(define (comptime-host-smoke-type-kind-data-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    [i64-kind : String "i64"]
    [string-kind : String "string"]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Type (compiler_ast_types.AstType.I64)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [matched : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-operand-type-kind-eq
            comptime-host-smoke-cookie
            0
            (comptime-host-smoke-name-ptr i64-kind)
            (string.string-length i64-kind))]
        [mismatched : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-operand-type-kind-eq
            comptime-host-smoke-cookie
            0
            (comptime-host-smoke-name-ptr string-kind)
            (string.string-length string-kind))]
        [malformed : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-operand-type-kind-eq
            comptime-host-smoke-cookie
            1
            (comptime-host-smoke-name-ptr i64-kind)
            (string.string-length i64-kind))]
        [after-data : i64
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-bool-literal
            1
            0)]
        [ok : bool
          (and
            (= matched 1)
            (= mismatched 0)
            (< malformed 0)
            (= after-data tlci_core.tlci-host-callback-status-ok))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Reflection result callbacks and their computed expression/pattern consumers
;; are the shared host surface used by the eight eq/hash fold bodies in #5626.
;; Keep a compact nominal metadata table here so this test exercises the
;; callback contract independently of the embedded-stdlib coverage census.
(define (comptime-host-smoke-reflections
  [pools : compiler_ast_types.AstNodePoolContext]) : compiler_ctfe.CtfeReflectInfoList
  (let
    [pair-id : i64 (ci.intern "HostSmokePair")]
    [choice-id : i64 (ci.intern "HostSmokeChoice")]
    [fields : compiler_ctfe.CtfeReflectFieldList
      (compiler_ctfe.ctfe-reflect-field-list-with-capacity 2)]
    [payloads : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-with-capacity 2)]
    [variants : compiler_ctfe.CtfeReflectVariantList
      (compiler_ctfe.ctfe-reflect-variant-list-with-capacity 2)]
    [infos : compiler_ctfe.CtfeReflectInfoList
      (compiler_ctfe.ctfe-reflect-info-list-with-capacity 2)]
    (begin
      (set!
        fields
        (compiler_ctfe.ctfe-reflect-field-list-push
          fields
          (compiler_ctfe.CtfeReflectField.Field
            (ci.intern "alpha")
            (compiler_ast_types.AstType.I64))))
      (set!
        fields
        (compiler_ctfe.ctfe-reflect-field-list-push
          fields
          (compiler_ctfe.CtfeReflectField.Field
            (ci.intern "beta")
            (compiler_ast_types.AstType.Bool))))
      (compiler_ast_types.ast-type-list-push
        (&mut payloads)
        (compiler_ast_types.ast-node-pool-context-type-push
          pools
          (compiler_ast_types.AstType.I64)))
      (compiler_ast_types.ast-type-list-push
        (&mut payloads)
        (compiler_ast_types.ast-node-pool-context-type-push
          pools
          (compiler_ast_types.AstType.Bool)))
      (set!
        variants
        (compiler_ctfe.ctfe-reflect-variant-list-push
          variants
          (compiler_ctfe.CtfeReflectVariant.Variant (ci.intern "Some") payloads)))
      (set!
        variants
        (compiler_ctfe.ctfe-reflect-variant-list-push
          variants
          (compiler_ctfe.CtfeReflectVariant.Variant
            (ci.intern "None")
            (compiler_ast_types.ast-type-list-new))))
      (set!
        infos
        (compiler_ctfe.ctfe-reflect-info-list-push-id
          infos
          (compiler_ctfe.CtfeReflectInfo.Struct
            "HostSmokePair"
            ""
            "HostSmokePair"
            pair-id
            (compiler_ctfe.CtfeReflectCleanup.No)
            fields)
          pair-id))
      (compiler_ctfe.ctfe-reflect-info-list-push-id
        infos
        (compiler_ctfe.CtfeReflectInfo.Enum
          "HostSmokeChoice"
          ""
          "HostSmokeChoice"
          choice-id
          (compiler_ctfe.CtfeReflectCleanup.No)
          variants)
        choice-id))))

(define (comptime-host-smoke-commit-result!) : bool
  (=
    (comptime-host-smoke-invoke
      compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
      0
      0)
    tlci_core.tlci-host-callback-status-ok))

;; The reflection builder test below batches several independent logical
;; invocations under one expensive metadata setup. Consume its synthetic result
;; between probes; real macro entries never receive this reset capability.
(define (comptime-host-smoke-consume-test-result!) : bool
  (begin
    (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-consume-for-test!)
    true))

(define (comptime-host-smoke-result-name? [expected : String]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Name text _) (string.eq text expected)]
    [(compiler_ctfe.CompilerCtfeValue.String text _) (string.eq text expected)]
    [_ false]))

(define (comptime-host-smoke-result-type? [expected-bool : bool]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Type ty)
      (if expected-bool
        (match ty
          [(compiler_ast_types.AstType.Bool) true]
          [_ false])
        (match ty
          [(compiler_ast_types.AstType.I64) true]
          [_ false]))]
    [_ false]))

(define (comptime-host-smoke-result-slice-i64?
  [pools : compiler_ast_types.AstNodePoolContext]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Type ty)
      (match ty
        [(compiler_ast_types.AstType.Slice elem)
          (match (compiler_ast_types.ast-node-pool-context-type-get pools elem)
            [(compiler_ast_types.AstType.I64) true]
            [_ false])]
        [_ false])]
    [_ false]))

;; The native type-slice wrapper and array-element-type callback share the
;; same value stack ABI as the other composite type callbacks. Use separate
;; sessions so the committed Slice shape and the unwrapped element are each
;; observed as the result value of a direct callback sequence.
(define (comptime-host-smoke-type-slice-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 0)]
    (begin
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        0
        8
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [scalar-status : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-scalar
            comptime-host-smoke-cookie
            0
            0
            0)]
        [slice-status : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-slice
            comptime-host-smoke-cookie
            0
            0
            0)]
        [commit-status : i64
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
            0
            0)]
        [constructed-ok : bool
          (and
            (= scalar-status tlci_core.tlci-host-callback-status-ok)
            (= slice-status tlci_core.tlci-host-callback-status-ok)
            (= commit-status tlci_core.tlci-host-callback-status-ok)
            (comptime-host-smoke-result-slice-i64? pools))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            0
            8
            comptime-host-smoke-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (let
            [scalar-status : i64
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-scalar
                comptime-host-smoke-cookie
                0
                0
                0)]
            [slice-status : i64
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-slice
                comptime-host-smoke-cookie
                0
                0
                0)]
            [element-status : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-array-element-type
                0
                0)]
            [commit-status : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
                0
                0)]
            [extracted-ok : bool
              (and
                (= scalar-status tlci_core.tlci-host-callback-status-ok)
                (= slice-status tlci_core.tlci-host-callback-status-ok)
                (= element-status tlci_core.tlci-host-callback-status-ok)
                (= commit-status tlci_core.tlci-host-callback-status-ok)
                (comptime-host-smoke-result-type? false))]
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
              (and constructed-ok extracted-ok))))))))

(define (comptime-host-smoke-result-tuple-bool-t?
  [pools : compiler_ast_types.AstNodePoolContext]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Type
        (compiler_ast_types.AstType.Tuple elems-box))
      (let
        [elems : compiler_ast_types.AstTypeList (__tl-box-place elems-box)]
        (and
          (= (compiler_ast_types.ast-type-list-len (& elems)) 2)
          (match (compiler_ast_types.ast-node-pool-context-type-get
            pools
            (compiler_ast_types.ast-type-list-get
              (& elems)
              0
              (compiler_ast_types.ast-type-id-fallback)))
            [(compiler_ast_types.AstType.Bool) true]
            [_ false])
          (match (compiler_ast_types.ast-node-pool-context-type-get
            pools
            (compiler_ast_types.ast-type-list-get
              (& elems)
              1
              (compiler_ast_types.ast-type-id-fallback)))
            [(compiler_ast_types.AstType.Var name-id)
              (string.eq (ci.intern-str name-id) "T")]
            [_ false])))]
    [_ false]))

;; Tuple type templates preserve source order and reject a non-Type stack
;; suffix without committing a result.
(define (comptime-host-smoke-type-tuple-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 0)]
    [type-name : String "T"]
    (begin
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        0
        16
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [positive : bool
          (and
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-scalar
                10
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-var
                (comptime-host-smoke-name-ptr type-name)
                (string.string-length type-name))
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-tuple
                2
                0)
              tlci_core.tlci-host-callback-status-ok)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-tuple-bool-t? pools))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            0
            8
            comptime-host-smoke-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (let
            [expr-status : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-bool-literal
                1
                0)]
            [malformed-status : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-tuple
                1
                0)]
            [malformed-ok : bool
              (and
                (= expr-status tlci_core.tlci-host-callback-status-ok)
                (=
                  malformed-status
                  tlci_core.tlci-host-callback-status-bad-request)
                (not
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)))]
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
              (and positive malformed-ok))))))))

(define (comptime-host-smoke-result-var-args?
  [expected-name : String]
  [expected-first : String]
  [expected-second : String]
  [expected-count : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Type
        (compiler_ast_types.AstType.VarArgs name lifetimes-box))
      (let
        [lifetimes : compiler_ast_types.AstLifetimeList
          (__tl-box-place lifetimes-box)]
        (and
          (= name (ci.intern expected-name))
          (=
            (compiler_ast_types.ast-lifetime-list-len (& lifetimes))
            expected-count)
          (=
            (compiler_ast_types.ast-lifetime-list-get
              (& lifetimes)
              0
              (compiler_ast_types.ast-lifetime-fallback))
            (ci.intern expected-first))
          (or
            (= expected-count 1)
            (=
              (compiler_ast_types.ast-lifetime-list-get
                (& lifetimes)
                1
                (compiler_ast_types.ast-lifetime-fallback))
              (ci.intern expected-second)))))]
    [_ false]))

;; Lifetime-parameterized unresolved nominal templates preserve exact name ids
;; and lifetime order. Malformed counts and empty fields fail without
;; publishing a result, even when another value is already on the stack.
(define (comptime-host-smoke-type-var-args-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 0)]
    [one : String "Borrowed\ntext"]
    [many : String "LifetimePair\nleft\nright"]
    [truncated : String "Broken\nonly"]
    (begin
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        0
        8
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [one-ok : bool
          (and
            (=
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-var-args
                comptime-host-smoke-cookie
                1
                (comptime-host-smoke-name-ptr one)
                (string.string-length one))
              tlci_core.tlci-host-callback-status-ok)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-var-args? "Borrowed" "text" "" 1))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            0
            8
            comptime-host-smoke-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (let
            [many-ok : bool
              (and
                (=
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-var-args
                    comptime-host-smoke-cookie
                    2
                    (comptime-host-smoke-name-ptr many)
                    (string.string-length many))
                  tlci_core.tlci-host-callback-status-ok)
                (comptime-host-smoke-commit-result!)
                (comptime-host-smoke-result-var-args?
                  "LifetimePair"
                  "left"
                  "right"
                  2))]
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
                pools
                operands
                0
                8
                comptime-host-smoke-cookie
                (compiler_ctfe.ctfe-reflect-info-list-empty))
              (let
                [seed-status : i64
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-scalar
                    comptime-host-smoke-cookie
                    0
                    0
                    0)]
                [malformed-status : i64
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-var-args
                    comptime-host-smoke-cookie
                    2
                    (comptime-host-smoke-name-ptr truncated)
                    (string.string-length truncated))]
                [malformed-ok : bool
                  (and
                    (= seed-status tlci_core.tlci-host-callback-status-ok)
                    (=
                      malformed-status
                      tlci_core.tlci-host-callback-status-bad-request)
                    (not
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)))]
                (begin
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
                  (and one-ok many-ok malformed-ok))))))))))

(define (comptime-host-smoke-result-array-take?
  [pools : compiler_ast_types.AstNodePoolContext]
  [target : i64]
  [live : i64]
  [index : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (compiler_ast_types.ast-node-pool-context-expr-get pools node)
        [(compiler_ast_types.AstExpr.ArrayTake
            actual-target
            actual-live
            actual-index)
          (and
            (= actual-target target)
            (= actual-live live)
            (= actual-index index))]
        [_ false])]
    [_ false]))

;; The dedicated array-take node consumes exactly three Expr values; an
;; underflow is a deterministic bad request.
(define (comptime-host-smoke-array-take-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [target : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "slots")))]
    [live : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "live")))]
    [index : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "index")))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 3)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr
          target
          (compiler_ast_types.AstType.Expr)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr
          live
          (compiler_ast_types.AstType.Expr)))
      (set!
        (array-ref operands 2)
        (compiler_ctfe.CompilerCtfeValue.Expr
          index
          (compiler_ast_types.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        3
        16
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [positive : bool
          (and
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                1
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                2
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-array-take
                0
                0)
              tlci_core.tlci-host-callback-status-ok)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-array-take? pools target live index))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            3
            8
            comptime-host-smoke-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (let
            [push-status : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)]
            [malformed-status : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-array-take
                0
                0)]
            [malformed-ok : bool
              (and
                (= push-status tlci_core.tlci-host-callback-status-ok)
                (=
                  malformed-status
                  tlci_core.tlci-host-callback-status-bad-request)
                (not
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)))]
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
              (and positive malformed-ok))))))))

(define (comptime-host-smoke-result-expr-typed-binding? [expected-init : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.LetBinding
        (compiler_ast_types.AstLetBinding.Binding name maybe-ty init))
      (and
        (string.eq (ci.intern-str name) "out")
        (= init expected-init)
        (match maybe-ty
          [(compiler_ast_types.AstMaybeType.Some
              (compiler_ast_types.AstType.Var type-name))
            (string.eq (ci.intern-str type-name) "Vec")]
          [_ false]))]
    [_ false]))

;; Typed template bindings accept an Expr containing type syntax, not only a
;; direct Type value. This is the path used by vector's computed `vec-name`.
;; A non-type Expr reports the same diagnostic as interpreted type unquote.
(define (comptime-host-smoke-expr-typed-binding-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [init-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "with-capacity")))]
    [type-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "Vec")))]
    [bad-type-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Literal
          (compiler_ast_types.AstLiteral.Unit)))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 3)]
    [binding-name : String "out"]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr
          init-node
          (compiler_ast_types.AstType.Expr)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr
          type-node
          (compiler_ast_types.AstType.Expr)))
      (set!
        (array-ref operands 2)
        (compiler_ctfe.CompilerCtfeValue.Expr
          bad-type-node
          (compiler_ast_types.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        3
        16
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [positive : bool
          (and
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                1
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-let-binding-typed
                (comptime-host-smoke-name-ptr binding-name)
                (string.string-length binding-name))
              tlci_core.tlci-host-callback-status-ok)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-expr-typed-binding? init-node))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            3
            16
            comptime-host-smoke-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (let
            [positive-push : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)]
            [malformed-push : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                2
                0)]
            [malformed-status : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-let-binding-typed
                (comptime-host-smoke-name-ptr binding-name)
                (string.string-length binding-name))]
            [malformed-ok : bool
              (and
                (= positive-push tlci_core.tlci-host-callback-status-ok)
                (= malformed-push tlci_core.tlci-host-callback-status-ok)
                (=
                  malformed-status
                  tlci_core.tlci-host-callback-status-diagnostic)
                (string.eq
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-diagnostic-text)
                  "type unquote expects a type expression")
                (not
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)))]
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
              (and positive malformed-ok))))))))

(define (comptime-host-smoke-result-bool? [expected : bool]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Bool value)
      (if expected
        value
        (not value))]
    [_ false]))

(define (comptime-host-smoke-result-captured-begin-items? [expected-node : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.CapturedExprList items _)
      (and
        (= (compiler_ctfe.ctfe-expr-list-length items) 1)
        (= (compiler_ctfe.ctfe-expr-list-nth items 0) expected-node))]
    [_ false]))

;; Local Expr destructuring retains Name, Int, and captured-list values, while
;; the bool data/value pair round-trips both immediate states. Wrong local
;; shapes and invalid immediates are rejected through their documented ABI
;; channel.
(define (comptime-host-smoke-local-values-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [var-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "core")))]
    [item-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Literal
          (compiler_ast_types.AstLiteral.Unit)))]
    [int-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Literal (compiler_ast_types.ast-lit-int 73)))]
    [items : compiler_ast_types.AstExprList
      (compiler_ast_types.ast-expr-list-with-capacity 1)]
    [begin-node : i64 0]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 4)]
    (begin
      (compiler_ast_types.ast-expr-list-push (&mut items) item-node)
      (set!
        begin-node
        (compiler_ast_types.ast-node-pool-context-expr-push
          pools
          (compiler_ast_types.AstExpr.Begin items)))
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr
          var-node
          (compiler_ast_types.AstType.Expr)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.CapturedExpr
          begin-node
          (compiler_ast_types.AstType.Expr)
          pools))
      (set! (array-ref operands 2) (compiler_ctfe.CompilerCtfeValue.Bool true))
      (set!
        (array-ref operands 3)
        (compiler_ctfe.CompilerCtfeValue.Expr
          int-node
          (compiler_ast_types.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        4
        32
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [positive : bool
          (and
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-set
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-set
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                2
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-set
                2
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                3
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-set
                3
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-var?
                0
                0)
              1)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-var-name
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-name? "core")
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-begin?
                1
                0)
              1)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-begin-items
                1
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-captured-begin-items? item-node)
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-int?
                3
                0)
              1)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-int-value
                3
                0)
              73)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-int?
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-bool-value
                2
                0)
              1)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-value-bool
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-bool? false)
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-bool-value
                0
                0)
              -3)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-begin?
                0
                0)
              0))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            4
            8
            comptime-host-smoke-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (let
            [invalid-bool : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-value-bool
                2
                0)]
            [malformed-ok : bool
              (and
                (= invalid-bool tlci_core.tlci-host-callback-status-bad-request)
                (not
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)))]
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
                pools
                operands
                4
                8
                comptime-host-smoke-cookie
                (compiler_ctfe.ctfe-reflect-info-list-empty))
              (let
                [push-status : i64
                  (comptime-host-smoke-invoke
                    compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                    2
                    0)]
                [set-status : i64
                  (comptime-host-smoke-invoke
                    compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-set
                    0
                    0)]
                [invalid-var : i64
                  (comptime-host-smoke-invoke
                    compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-var-name
                    0
                    0)]
                [wrong-local-ok : bool
                  (and
                    (= push-status 0)
                    (= set-status 0)
                    (=
                      invalid-var
                      tlci_core.tlci-host-callback-status-bad-request))]
                (begin
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
                    pools
                    operands
                    4
                    8
                    comptime-host-smoke-cookie
                    (compiler_ctfe.ctfe-reflect-info-list-empty))
                  (let
                    [push-var-status : i64
                      (comptime-host-smoke-invoke
                        compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                        0
                        0)]
                    [set-var-status : i64
                      (comptime-host-smoke-invoke
                        compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-set
                        0
                        0)]
                    [invalid-begin : i64
                      (comptime-host-smoke-invoke
                        compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-begin-items
                        0
                        0)]
                    [wrong-begin-ok : bool
                      (and
                        (= push-var-status 0)
                        (= set-var-status 0)
                        (=
                          invalid-begin
                          tlci_core.tlci-host-callback-status-bad-request))]
                    (begin
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
                      (and positive malformed-ok wrong-local-ok wrong-begin-ok))))))))))))

;; Large module generators address locals by immediate slot. Pin the high end
;; of vector's 64-slot producer/host budget and reject the first slot beyond it.
(define (comptime-host-smoke-local-capacity-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set! (array-ref operands 0) (compiler_ctfe.CompilerCtfeValue.Bool true))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [positive : bool
          (and
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-set
                63
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-get
                63
                0)
              tlci_core.tlci-host-callback-status-ok)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-bool? true))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            1
            8
            comptime-host-smoke-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (let
            [push-status : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)]
            [overflow-status : i64
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-set
                64
                0)]
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
              (and
                positive
                (= push-status tlci_core.tlci-host-callback-status-ok)
                (=
                  overflow-status
                  tlci_core.tlci-host-callback-status-bad-request)))))))))

;; The native callback value stack is fuel-bounded rather than carrying a
;; second, lower fixed ceiling. Formatting a long variadic argument list is one
;; real workload whose generated transformer can exceed the initial 64 slots.
(define (comptime-host-smoke-stack-growth-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (set! (array-ref operands 0) (compiler_ctfe.CompilerCtfeValue.Bool true))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        1
        128
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (while (and ok (< index 65))
        (begin
          (if (=
            (comptime-host-smoke-invoke
              compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
              0
              0)
            tlci_core.tlci-host-callback-status-ok)
            unit
            (set! ok false))
          (set! index (+ index 1))))
      (let
        [grown? : bool
          (and
            ok
            (=
              compiler_embedded_stdlib_tlci.compiler-comptime-host-stack-len
              65)
            (>=
              (array-length
                compiler_embedded_stdlib_tlci.compiler-comptime-host-stack)
              128))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          grown?)))))

(define (comptime-host-smoke-result-shared-let-scope?
  [pools : compiler_ast_types.AstNodePoolContext]
  [binding-name : i64]
  [init-node : i64]
  [body-node : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr result-node _)
      (match (compiler_ast_types.ast-node-pool-context-expr-get
        pools
        result-node)
        [(compiler_ast_types.AstExpr.Let let-box)
          (match (__tl-box-place let-box)
            [(compiler_ast_types.AstLet.Let bindings actual-body)
              (and
                (= actual-body body-node)
                (= (compiler_ast_types.ast-let-binding-list-len (& bindings)) 1)
                (match (compiler_ast_types.ast-let-binding-list-get
                  (& bindings)
                  0
                  (compiler_ast_types.ast-let-binding-fallback))
                  [(compiler_ast_types.AstLetBinding.Binding
                      actual-name
                      (compiler_ast_types.AstMaybeType.No)
                      borrow-node)
                    (and
                      (= actual-name binding-name)
                      (match (compiler_ast_types.ast-node-pool-context-expr-get
                        pools
                        borrow-node)
                        [(compiler_ast_types.AstExpr.Borrow
                            mutable?
                            lifetime-id
                            actual-init)
                          (and
                            (not mutable?)
                            (match (compiler_ast_types.ast-borrow-lifetime-from-id
                              lifetime-id)
                              [(compiler_ast_types.AstBorrowLifetime.Inferred)
                                true]
                              [_ false])
                            (= actual-init init-node))]
                        [_ false]))]
                  [_ false]))])]
        [_ false])]
    [_ false]))

;; The ownership-preserving format path uses this callback directly in native
;; macro images. Pin the direct-place form and the stable stack-base restoration
;; after the preceding growth test independently of format expansion.
(define (comptime-host-smoke-shared-let-scope-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [binding-name : i64 (ci.intern "shared")]
    [init-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "owner")))]
    [body-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var binding-name))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 3)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Name "shared" binding-name))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr
          init-node
          (compiler_ast_types.AstType.Expr)))
      (set!
        (array-ref operands 2)
        (compiler_ctfe.CompilerCtfeValue.Expr
          body-node
          (compiler_ast_types.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        3
        16
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [base-restored? : bool
          (=
            (array-length
              compiler_embedded_stdlib_tlci.compiler-comptime-host-stack)
            64)]
        [positive : bool
          (and
            base-restored?
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                1
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                2
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-shared-let-scope
                0
                0)
              tlci_core.tlci-host-callback-status-ok)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-shared-let-scope?
              pools
              binding-name
              init-node
              body-node))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          positive)))))

(define (comptime-host-smoke-result-lambda1?
  [pools : compiler_ast_types.AstNodePoolContext]
  [parameter-name : i64]
  [parameter-type : compiler_ast_types.AstType]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr result-node produced)
      (and
        (compiler_ctfe.ctfe-untyped-expr-type? produced)
        (match (compiler_ast_types.ast-node-pool-context-expr-get
          pools
          result-node)
          [(compiler_ast_types.AstExpr.Lambda lambda-box)
            (match (__tl-box-place lambda-box)
              [(compiler_ast_types.AstLambda.Lambda params maybe-ret body-node)
                (and
                  (= (compiler_ast_types.ast-param-list-len (& params)) 1)
                  (match (compiler_ast_types.ast-param-list-get
                    (& params)
                    0
                    (compiler_ast_types.ast-param-fallback))
                    [(compiler_ast_types.AstParam.Param
                        actual-name
                        actual-type
                        false
                        false)
                      (and
                        (= actual-name parameter-name)
                        (compiler_ctfe.ctfe-type-eq actual-type parameter-type))]
                    [_ false])
                  (match maybe-ret
                    [(compiler_ast_types.AstMaybeType.No) true]
                    [(compiler_ast_types.AstMaybeType.Some _) false])
                  (match (compiler_ast_types.ast-node-pool-context-expr-get
                    pools
                    body-node)
                    [(compiler_ast_types.AstExpr.TupleRef target-node 1)
                      (match (compiler_ast_types.ast-node-pool-context-expr-get
                        pools
                        target-node)
                        [(compiler_ast_types.AstExpr.Var actual-name)
                          (= actual-name parameter-name)]
                        [_ false])]
                    [_ false]))])]
          [_ false]))]
    [_ false]))

;; Pin the native computed-lambda callback independently of package generation:
;; its reflected heterogeneous reference tuple and preassembled projection
;; become one hygienic parameter/body pair. Refs #6868.
(define (comptime-host-smoke-expr-lambda1-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [parameter-name : i64 (ci.intern "lambda1-values")]
    [owner-name : i64 (ci.intern "Lambda1Owner")]
    [owner-region : i64 (ci.intern "lambda1-owner-region")]
    [text-region : i64 (ci.intern "lambda1-text-region")]
    [parameter-type : compiler_ast_types.AstType
      (compiler_ast_types.ast-ty-tuple
        (compiler_ast_types.ast-type-cons-with-pools
          pools
          (compiler_ast_types.ast-ty-ref-with-pools
            pools
            owner-region
            (compiler_ast_types.AstType.Var owner-name))
          (compiler_ast_types.ast-type-cons-with-pools
            pools
            (compiler_ast_types.ast-ty-ref-with-pools
              pools
              text-region
              (compiler_ast_types.AstType.Str))
            (compiler_ast_types.ast-type-list-new))))]
    [target-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var parameter-name))]
    [body-node : i64
      (compiler_ast_types.ast-expr-tuple-ref-with-pools pools target-node 1)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 3)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Name "lambda1-values" parameter-name))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Type parameter-type))
      (set!
        (array-ref operands 2)
        (compiler_ctfe.CompilerCtfeValue.Expr
          body-node
          (compiler_ctfe.ctfe-untyped-expr-type)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        3
        16
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [positive : bool
          (and
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                1
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                2
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-lambda1
                0
                0)
              tlci_core.tlci-host-callback-status-ok)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-lambda1?
              pools
              parameter-name
              parameter-type))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          positive)))))

(define (comptime-host-smoke-result-string-expr?
  [pools : compiler_ast_types.AstNodePoolContext]
  [expected : String]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (compiler_ast_types.ast-node-pool-context-expr-get pools node)
        [(compiler_ast_types.AstExpr.Literal
            (compiler_ast_types.AstLiteral.String string-id))
          (string.eq (ci.intern-str string-id) expected)]
        [_ false])]
    [_ false]))

(define (comptime-host-smoke-result-struct-get?
  [pools : compiler_ast_types.AstNodePoolContext]
  [target : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (compiler_ast_types.ast-node-pool-context-expr-get pools node)
        [(compiler_ast_types.AstExpr.StructGet actual field)
          (and (= actual target) (string.eq (ci.intern-str field) "alpha"))]
        [_ false])]
    [_ false]))

(define (comptime-host-smoke-result-struct-set?
  [pools : compiler_ast_types.AstNodePoolContext]
  [target : i64]
  [field-id : i64]
  [value : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr
        node
        (compiler_ast_types.AstType.Unit))
      (match (compiler_ast_types.ast-node-pool-context-expr-get pools node)
        [(compiler_ast_types.AstExpr.StructSet
            actual-target
            actual-field
            actual-value)
          (and
            (= actual-target target)
            (= actual-field field-id)
            (= actual-value value))]
        [_ false])]
    [_ false]))

;; Computed struct assignment accepts both structural Name identities and
;; String values, and rejects every other field kind without producing a
;; result. Exercise the callback independently of the embedded-package census.
;; Refs #5999.
(define (comptime-host-smoke-struct-set-from-value-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [target-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "target")))]
    [value-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "value")))]
    [name-id : i64 (ci.intern "name-field")]
    [string-id : i64 (ci.intern "string-field")]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 5)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr
          target-node
          (compiler_ast_types.AstType.Expr)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Name "name-field" name-id))
      (set!
        (array-ref operands 2)
        (compiler_ctfe.CompilerCtfeValue.String "string-field" string-id))
      (set!
        (array-ref operands 3)
        (compiler_ctfe.CompilerCtfeValue.Expr
          value-node
          (compiler_ast_types.AstType.Expr)))
      (set! (array-ref operands 4) (compiler_ctfe.CompilerCtfeValue.Bool false))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        5
        16
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [name-ok : bool
          (and
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                1
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                3
                0)
              tlci_core.tlci-host-callback-status-ok)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-struct-set-from-value
                0
                0)
              tlci_core.tlci-host-callback-status-ok)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-struct-set?
              pools
              target-node
              name-id
              value-node))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            5
            16
            comptime-host-smoke-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (let
            [string-ok : bool
              (and
                (=
                  (comptime-host-smoke-invoke
                    compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                    0
                    0)
                  tlci_core.tlci-host-callback-status-ok)
                (=
                  (comptime-host-smoke-invoke
                    compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                    2
                    0)
                  tlci_core.tlci-host-callback-status-ok)
                (=
                  (comptime-host-smoke-invoke
                    compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                    3
                    0)
                  tlci_core.tlci-host-callback-status-ok)
                (=
                  (comptime-host-smoke-invoke
                    compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-struct-set-from-value
                    0
                    0)
                  tlci_core.tlci-host-callback-status-ok)
                (comptime-host-smoke-commit-result!)
                (comptime-host-smoke-result-struct-set?
                  pools
                  target-node
                  (compiler_ctfe.ctfe-string-syntax-name-id
                    (compiler_ctfe.ctfe-env-source-names
                      (compiler_ctfe.ctfe-env-empty-with-pools pools))
                    "string-field"
                    string-id)
                  value-node))]
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
                pools
                operands
                5
                16
                comptime-host-smoke-cookie
                (compiler_ctfe.ctfe-reflect-info-list-empty))
              (let
                [malformed-ok : bool
                  (and
                    (=
                      (comptime-host-smoke-invoke
                        compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                        0
                        0)
                      tlci_core.tlci-host-callback-status-ok)
                    (=
                      (comptime-host-smoke-invoke
                        compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                        4
                        0)
                      tlci_core.tlci-host-callback-status-ok)
                    (=
                      (comptime-host-smoke-invoke
                        compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                        3
                        0)
                      tlci_core.tlci-host-callback-status-ok)
                    (=
                      (comptime-host-smoke-invoke
                        compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-struct-set-from-value
                        0
                        0)
                      tlci_core.tlci-host-callback-status-bad-request)
                    (not
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)))]
                (begin
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
                  (and name-ok string-ok malformed-ok))))))))))

(define (comptime-host-smoke-result-tuple-ref?
  [pools : compiler_ast_types.AstNodePoolContext]
  [target : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (compiler_ast_types.ast-node-pool-context-expr-get pools node)
        [(compiler_ast_types.AstExpr.TupleRef actual index)
          (and (= actual target) (= index 1))]
        [_ false])]
    [_ false]))

(define (comptime-host-smoke-result-reflected-match?
  [pools : compiler_ast_types.AstNodePoolContext]
  [scrutinee : i64]
  [body : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (compiler_ast_types.ast-node-pool-context-expr-get pools node)
        [(compiler_ast_types.AstExpr.Match match-box)
          (match (__tl-box-place match-box)
            [(compiler_ast_types.AstMatch.Match actual arms)
              (and
                (= actual scrutinee)
                (= arms.len 1)
                (match (array-ref arms.slots 0)
                  [(compiler_ast_types.AstMatchArm.Arm pattern actual-body)
                    (and
                      (= actual-body body)
                      (match pattern
                        [(compiler_ast_types.AstPattern.Variant name args-box)
                          (let
                            [args : compiler_ast_types.AstPatternList
                              (__tl-box-place args-box)]
                            (and
                              (string.eq (ci.intern-str name) "Some")
                              (= args.len 2)
                              (match (array-ref args.slots 0)
                                [(compiler_ast_types.AstPattern.Binding first)
                                  (string.eq (ci.intern-str first) "p0")]
                                [_ false])
                              (match (array-ref args.slots 1)
                                [(compiler_ast_types.AstPattern.Binding second)
                                  (string.eq (ci.intern-str second) "p1")]
                                [_ false])))]
                        [_ false]))]
                  [_ false]))]
            [_ false])]
        [_ false])]
    [_ false]))

(define (comptime-host-smoke-reflection-builders-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [pair-id : i64 (ci.intern "HostSmokePair")]
    [choice-id : i64 (ci.intern "HostSmokeChoice")]
    [tuple-items : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-with-capacity 2)]
    [value-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "value")))]
    [body-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Literal
          (compiler_ast_types.AstLiteral.Bool true)))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 5)]
    [prefix : String "p"]
    (begin
      (compiler_ast_types.ast-type-list-push
        (&mut tuple-items)
        (compiler_ast_types.ast-node-pool-context-type-push
          pools
          (compiler_ast_types.AstType.I64)))
      (compiler_ast_types.ast-type-list-push
        (&mut tuple-items)
        (compiler_ast_types.ast-node-pool-context-type-push
          pools
          (compiler_ast_types.AstType.Bool)))
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Type
          (compiler_ast_types.AstType.Struct pair-id)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Type
          (compiler_ast_types.AstType.Enum choice-id)))
      (set!
        (array-ref operands 2)
        (compiler_ctfe.CompilerCtfeValue.Type
          (compiler_ast_types.AstType.Tuple (box tuple-items))))
      (set!
        (array-ref operands 3)
        (compiler_ctfe.CompilerCtfeValue.Expr
          value-node
          (compiler_ast_types.AstType.Expr)))
      (set!
        (array-ref operands 4)
        (compiler_ctfe.CompilerCtfeValue.Expr
          body-node
          (compiler_ast_types.AstType.Bool)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
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
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-struct-field-count
                0
                0)
              2)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                2
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-tuple-element-count
                0
                0)
              2)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-enum-variant-count
                0
                0)
              2)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-enum-variant-payload-count
                0
                0)
              2)
            ;; Name and type queries preserve the same values as interpreted
            ;; reflection.
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-struct-field-name
                1
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-name? "beta")
            (comptime-host-smoke-consume-test-result!)
            ;; `expr-string` accepts the reflected Name just like interpreted
            ;; `ctfe-eval-string-arg`; serialize uses this exact chain for
            ;; generated object keys.
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-struct-field-name
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-string-from-value
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-string-expr? pools "alpha")
            (comptime-host-smoke-consume-test-result!)
            ;; Interpreted String arguments accept reflected Name values too:
            ;; this exact `"." + field-name` shape is used by struct hashing.
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-string-value
                (comptime-host-smoke-name-ptr ".")
                1)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-struct-field-name
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-string-append
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-name? ".alpha")
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-struct-field-type
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-type? false)
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                2
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-tuple-element-type
                1
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-type? true)
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-enum-variant-name
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-name? "Some")
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-enum-variant-payload-type
                0
                1)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-type? true)
            (comptime-host-smoke-consume-test-result!)
            ;; Dynamic projections consume reflected names/indexes.
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                3
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-struct-field-name
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-struct-get-from-value
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-struct-get? pools value-node)
            (comptime-host-smoke-consume-test-result!)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                3
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-tuple-ref
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
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                3
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-enum-variant-name
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-string-value
                (comptime-host-smoke-name-ptr prefix)
                (string.string-length prefix))
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-pattern-list-bindings
                2
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-pattern-variant-from-value
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                4
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-match-arm
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-match-arm-list-empty
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-match-arm-list-cons-from-values
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-match
                0
                0)
              0)
            (comptime-host-smoke-commit-result!)
            (comptime-host-smoke-result-reflected-match?
              pools
              value-node
              body-node))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Dense binding construction charges one unit per generated payload binding
;; and rejects the request before allocating when the shared session budget is
;; too small.
(define (comptime-host-smoke-pattern-binding-fuel-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    [prefix : String "p"]
    (begin
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        0
        1
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (and
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-string-value
                (comptime-host-smoke-name-ptr prefix)
                (string.string-length prefix))
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-pattern-list-bindings
                2
                0)
              tlci_core.tlci-host-callback-status-fuel-exhausted))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Native sequence folds must publish the same exact-root hygiene exemption as
;; their interpreted CTFE counterparts. Otherwise a later handoff clones and
;; reattributes captured caller syntax through the macro definition context.
(define (comptime-host-smoke-expr-list-fold-hygiene-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [condition-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "flag")))]
    [items : compiler_ast_types.AstExprList
      (compiler_ast_types.ast-expr-cons
        condition-node
        (compiler_ast_types.ast-expr-list-new))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.ExprList items))
      (compiler_ctfe.ctfe-result-hygiene-free-reset!)
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (and
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-bool-literal
                1
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-bool-literal
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-list-fold-if
                0
                1)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
                0
                0)
              0)
            (comptime-host-smoke-result-is-hygiene-free?))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (comptime-host-smoke-clause-list-fold-hygiene-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [condition-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "flag")))]
    [result-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Literal
          (compiler_ast_types.AstLiteral.Bool true)))]
    [else-node : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        pools
        (compiler_ast_types.AstExpr.Var (ci.intern "else")))]
    [clauses : compiler_ast_types.AstExprClauseList
      (compiler_ast_types.ast-expr-clause-list-new)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (compiler_ast_types.ast-expr-clause-list-push
        (&mut clauses)
        (compiler_ast_types.ast-expr-clause condition-node result-node))
      (compiler_ast_types.ast-expr-clause-list-push
        (&mut clauses)
        (compiler_ast_types.ast-expr-clause else-node result-node))
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.ExprClauseList clauses))
      (compiler_ctfe.ctfe-result-hygiene-free-reset!)
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (and
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-bool-literal
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-bool-literal
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-clause-list-fold-if
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
                0
                0)
              0)
            (comptime-host-smoke-result-is-hygiene-free?))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (comptime-host-smoke-call-provenance-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    [macro-name : String "nested-macro"]
    [macro-name-id : i64 (ci.intern macro-name)]
    (begin
      (compiler_ctfe.ctfe-visible-macro-names-reset!)
      (compiler_ctfe.ctfe-visible-macro-name-add! macro-name-id)
      (compiler_ctfe.ctfe-result-macro-provenance-reset!)
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        0
        8
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (and
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-var
                (comptime-host-smoke-name-ptr macro-name)
                (string.string-length macro-name))
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-list-empty
                0
                0)
              0)
            (=
              (comptime-host-smoke-invoke
                compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-call
                0
                0)
              0)
            (compiler_ctfe.ctfe-result-may-contain-macro?))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; One invocation owns one public result slot. A buggy native entry must not
;; overwrite its first committed handle; the second commit is a bad request,
;; leaves the first value intact, and poisons the remainder of the session.
(define (comptime-host-smoke-single-commit-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set! (array-ref operands 0) (compiler_ctfe.CompilerCtfeValue.Bool true))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [first-push : i64
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
            0
            0)]
        [first-commit : i64
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
            0
            0)]
        [second-push : i64
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-bool-literal
            0
            0)]
        [second-commit : i64
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
            0
            0)]
        [first-result-kept : bool
          (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
            [(compiler_ctfe.CompilerCtfeValue.Bool flag) flag]
            [_ false])]
        [latched : i64
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-unit-literal
            0
            0)]
        [ok : bool
          (and
            (= first-push tlci_core.tlci-host-callback-status-ok)
            (= first-commit tlci_core.tlci-host-callback-status-ok)
            (= second-push tlci_core.tlci-host-callback-status-ok)
            (= second-commit tlci_core.tlci-host-callback-status-bad-request)
            first-result-kept
            (= latched tlci_core.tlci-host-callback-status-bad-request))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Statuses: stale cookie, empty-stack commit, and fuel exhaustion all answer
;; without committing state.
(define (comptime-host-smoke-status-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        0
        1
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (and
        (=
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-list-empty
            0x9999
            0
            0
            0)
          tlci_core.tlci-host-callback-status-bad-request)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
            0
            0)
          tlci_core.tlci-host-callback-status-bad-request)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-fuel-check
            0
            0)
          tlci_core.tlci-host-callback-status-bad-request)
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            0
            1
            comptime-host-smoke-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          true)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-fuel-check
            0
            0)
          0)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-fuel-check
            0
            0)
          tlci_core.tlci-host-callback-status-fuel-exhausted)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-list-empty
            0
            0)
          tlci_core.tlci-host-callback-status-fuel-exhausted)
        (not
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?))))))

;; The fixed abort-table callback latches status 3 after an entry has staged a
;; value but before commit. The attempted commit must return that status and
;; leave the public result slot empty.
(define (comptime-host-smoke-abort-no-commit-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    [message : String "native comptime abort control"]
    (begin
      (set! (array-ref operands 0) (compiler_ctfe.CompilerCtfeValue.Bool true))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        pools
        operands
        1
        8
        comptime-host-smoke-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (and
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
            0
            0)
          tlci_core.tlci-host-callback-status-ok)
        (=
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-abort
            comptime-host-smoke-cookie
            7
            (comptime-host-smoke-name-ptr message)
            (string.string-length message)
            0)
          tlci_core.tlci-host-callback-status-ok)
        (=
          (comptime-host-smoke-invoke
            compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
            0
            0)
          tlci_core.tlci-host-callback-status-abort)
        (not
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?))))))

(define (comptime-host-smoke-closed-session-ok?) : bool
  (begin
    (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
    (=
      (comptime-host-smoke-invoke
        compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-list-empty
        0
        0)
      tlci_core.tlci-host-callback-status-bad-request)))

(define (comptime-host-smoke-table-ok?) : bool
  (match (tlci_core.tlci-validate-host-callback-table
    (compiler_embedded_stdlib_tlci.compiler-comptime-host-table))
    [(tlci_core.ResultTlciHostAbi.Ok) true]
    [(tlci_core.ResultTlciHostAbi.Err _) false]))

(define (main) : i64
  (cond
    [(not (comptime-host-smoke-construct-ok?))
      (io.panic "comptime host smoke: construction")]
    [(not (comptime-host-smoke-type-kind-data-ok?))
      (io.panic "comptime host smoke: type-kind data status")]
    [(not (comptime-host-smoke-type-slice-ok?))
      (io.panic "comptime host smoke: type-slice callback")]
    [(not (comptime-host-smoke-type-tuple-ok?))
      (io.panic "comptime host smoke: type-tuple callback")]
    [(not (comptime-host-smoke-type-var-args-ok?))
      (io.panic "comptime host smoke: type-var-args callback")]
    [(not (comptime-host-smoke-array-take-ok?))
      (io.panic "comptime host smoke: array-take callback")]
    [(not (comptime-host-smoke-expr-typed-binding-ok?))
      (io.panic "comptime host smoke: expression-typed binding callback")]
    [(not (comptime-host-smoke-local-values-ok?))
      (io.panic "comptime host smoke: local value callbacks")]
    [(not (comptime-host-smoke-local-capacity-ok?))
      (io.panic "comptime host smoke: local capacity callbacks")]
    [(not (comptime-host-smoke-stack-growth-ok?))
      (io.panic "comptime host smoke: value stack growth")]
    [(not (comptime-host-smoke-shared-let-scope-ok?))
      (io.panic "comptime host smoke: shared let scope callback")]
    [(not (comptime-host-smoke-expr-lambda1-ok?))
      (io.panic "comptime host smoke: computed lambda callback")]
    [(not (comptime-host-smoke-reflection-builders-ok?))
      (io.panic "comptime host smoke: reflection builders")]
    [(not (comptime-host-smoke-struct-set-from-value-ok?))
      (io.panic "comptime host smoke: computed struct set")]
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
    [(not (comptime-host-smoke-abort-no-commit-ok?))
      (io.panic "comptime host smoke: abort no-partial-commit contract")]
    [(not (comptime-host-smoke-closed-session-ok?))
      (io.panic "comptime host smoke: closed session")]
    [(not (comptime-host-smoke-table-ok?))
      (io.panic "comptime host smoke: host table")]
    [else 42]))