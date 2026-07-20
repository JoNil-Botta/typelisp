;; comptime_host_smoke.tl - Compiler-owned native-comptime host session smoke.
;;
;; Drives the callback-invoke dispatcher directly through the operation
;; sequence a natively compiled `(f ,x)` quasiquote body will emit, and
;; asserts the committed result is the same AST shape the interpreted
;; builders produce, plus the status contract for stale cookies, empty-stack
;; commits, unknown operations, and fuel exhaustion. Refs #5212.
(import "../compiler_embedded_stdlib_tlci.tl")
(import "../tlci_core.tl")
(import "../tlci_loader.tl")
(import compiler_comptime_image_core as comptime_image)
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

;; End-to-end native path: lower the exact stdlib.array/length operation
;; sequence into a real image, map it through the production W^X loader with
;; the compiler-owned host table, dispatch the entry, and assert the host
;; session committed the same AST shape the interpreted builders produce.
(define (comptime-host-smoke-native-image-bytes) : ResultTlciBytes
  (let
    [pool-names : (Array String) (array.make-array String 1)]
    [_pool : unit (array-set! pool-names 0 "__tl_array-length")]
    (match (comptime_image.compiler-comptime-lower-probe
      (comptime_image.CompilerComptimeMacroProgram
        "smoke/array-length"
        (make-array
          (comptime_image.CompilerComptimeOperation.HostCallName
            tlci-host-callback-op-expr-var
            0)
          (comptime_image.CompilerComptimeOperation.HostCall
            tlci-host-callback-op-expr-list-empty)
          (comptime_image.CompilerComptimeOperation.HostCallArgs
            tlci-host-callback-op-push-operand
            0
            0
            0)
          (comptime_image.CompilerComptimeOperation.HostCall
            tlci-host-callback-op-expr-list-append)
          (comptime_image.CompilerComptimeOperation.HostCall
            tlci-host-callback-op-expr-call)
          (comptime_image.CompilerComptimeOperation.HostCall
            tlci-host-callback-op-commit-result))
        pool-names
        0x5151
        0)
      false)
      [(comptime_image.ResultCompilerComptimeImagePayload.Err message)
        (ResultTlciBytes.Err message)]
      [(comptime_image.ResultCompilerComptimeImagePayload.Ok payload)
        (tlci-emit-code-bearing-probe-image
          (struct-get payload code)
          (struct-get payload macro-entry-offset)
          (struct-get payload macro-table-offset)
          (struct-get payload macro-name-offset))])))

(define (comptime-host-smoke-native-image-ok?) : bool
  (match (comptime-host-smoke-native-image-bytes)
    [(ResultTlciBytes.Err _) false]
    [(ResultTlciBytes.Ok bytes)
      (match (tlci-loader-load-from-bytes-with-host
        bytes
        (compiler-comptime-host-table))
        [(ResultTlciLoadedImage.Err _) false]
        [(ResultTlciLoadedImage.Ok loaded)
          (let
            [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
            [operand-node : i64
              (ast-node-pool-context-expr-push
                pools
                (AstExpr.Var (ci.intern "x")))]
            [operands : (Array CompilerCtfeValue)
              (array.make-array CompilerCtfeValue 1)]
            (begin
              (array-set!
                operands
                0
                (CompilerCtfeValue.Expr operand-node (AstType.Expr)))
              (compiler-comptime-host-session-open!
                pools
                operands
                1
                32
                comptime-host-smoke-cookie
                (ctfe-reflect-info-list-empty))
              (let
                [ok : bool
                  (match (tlci-loader-dispatch-macro
                    (& loaded)
                    "smoke/array-length"
                    comptime-host-smoke-cookie
                    (array.make-array i64 0)
                    0)
                    [(ResultTlciMacroDispatch.Err _) false]
                    [(ResultTlciMacroDispatch.Ok dispatch)
                      (and
                        (= (struct-get dispatch status) 0)
                        (compiler-comptime-host-result-ready?)
                        (comptime-host-smoke-result-shape-ok?
                          pools
                          operand-node))])]
                (begin
                  (compiler-comptime-host-session-close!)
                  (match (tlci-loader-release loaded)
                    [(ResultTlciLoaderUnit.Ok) ok]
                    [(ResultTlciLoaderUnit.Err _) false])))))])]))

(define (comptime-host-smoke-table-ok?) : bool
  (match (tlci-validate-host-callback-table (compiler-comptime-host-table))
    [(ResultTlciHostAbi.Ok) true]
    [(ResultTlciHostAbi.Err _) false]))

(define (main) : i64
  (if (and
    (comptime-host-smoke-construct-ok?)
    (comptime-host-smoke-status-ok?)
    (comptime-host-smoke-closed-session-ok?)
    (comptime-host-smoke-table-ok?)
    (comptime-host-smoke-native-image-ok?))
    42
    1))