;; comptime_host_smoke.tl - Compiler-owned native-comptime host session smoke.
;;
;; Drives the callback-invoke dispatcher directly through the operation
;; sequence a natively compiled `(f ,x)` quasiquote body will emit, and
;; asserts the committed result is the same AST shape the interpreted
;; builders produce, plus the status contract for stale cookies, empty-stack
;; commits, unknown operations, and fuel exhaustion. Refs #5212.
(import "../compiler_embedded_stdlib_tlci.tl")
(import "../tlci_core.tl")
(import "../compiler_ast_types.tl")
(import "../compiler_ctfe.tl")
(import compiler_intern as ci)
(import stdlib.array)
(import stdlib.string)

(define comptime-host-smoke-cookie : i64
  0x5151)

(define (comptime-host-smoke-name-ptr [name : String]) : i64
  (cast
    (unsafe
      (ptr->int (string-data name)))
    : i64))

(define (comptime-host-smoke-invoke [operation : i64] [a : i64] [b : i64]) : i64
  (compiler-comptime-host-invoke 0 comptime-host-smoke-cookie operation a b 0))

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
        comptime-host-smoke-cookie)
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
                (= name-id (ci.intern "__tl_array-length"))]
              [_ false])
            (= (ast-expr-list-len (& args)) 1)
            (= (ast-expr-list-get (& args) 0 -1) operand-node))]
        [_ false])]
    [_ false]))

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
        comptime-host-smoke-cookie)
      (and
        (=
          (compiler-comptime-host-invoke
            0
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
        (= (comptime-host-smoke-invoke tlci-host-callback-op-fuel-check 0 0) 0)
        (=
          (comptime-host-smoke-invoke tlci-host-callback-op-fuel-check 0 0)
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
  (if (and
    (comptime-host-smoke-construct-ok?)
    (comptime-host-smoke-status-ok?)
    (comptime-host-smoke-closed-session-ok?)
    (comptime-host-smoke-table-ok?))
    42
    1))