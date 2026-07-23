;; comptime_host_smoke.tl - Compiler-owned native-comptime host session smoke.
;;
;; Drives the callback-invoke dispatcher directly through the operation
;; sequence a natively compiled `(f ,x)` quasiquote body will emit, and
;; asserts the committed result is the same AST shape the interpreted
;; builders produce. It also checks macro-call provenance, fold hygiene-marker
;; parity, and the status contract for stale cookies, empty-stack commits,
;; unknown operations, and fuel exhaustion. Refs #5212, #5475, #5503.
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
    [(not (comptime-host-smoke-expr-list-fold-hygiene-ok?))
      (io.panic "comptime host smoke: expression fold hygiene")]
    [(not (comptime-host-smoke-clause-list-fold-hygiene-ok?))
      (io.panic "comptime host smoke: clause fold hygiene")]
    [(not (comptime-host-smoke-call-provenance-ok?))
      (io.panic "comptime host smoke: call provenance")]
    [(not (comptime-host-smoke-status-ok?))
      (io.panic "comptime host smoke: status contract")]
    [(not (comptime-host-smoke-closed-session-ok?))
      (io.panic "comptime host smoke: closed session")]
    [(not (comptime-host-smoke-table-ok?))
      (io.panic "comptime host smoke: host table")]
    [else 42]))