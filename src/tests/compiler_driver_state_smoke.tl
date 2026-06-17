(import "compiler_driver_core.tl")

(define (compiler-driver-state-smoke-expr-push
  [pool : AstExprNodePoolState]
  [value : i64]) : AstExprNodePoolState
  (match (ast-expr-node-pool-state-push pool (AstExprLiteral (AstLitInt value)))
    [(AstExprNodePoolPushOk next _) next]))

(define (compiler-driver-state-smoke-type-push
  [pool : AstTypeNodePoolState]
  [node : AstType]) : AstTypeNodePoolState
  (match (ast-type-node-pool-state-push pool node)
    [(AstTypeNodePoolPushOk next _) next]))

(define (compiler-driver-state-smoke-expr-int?
  [pool : AstExprNodePoolState]
  [id : i64]
  [expected : i64]) : bool
  (match (ast-expr-node-pool-state-get pool id)
    [(AstExprLiteral lit)
      (match lit
        [(AstLitInt value) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-driver-state-smoke-type-i64?
  [pool : AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast-type-node-pool-state-get pool id)
    [(AstTyI64) true]
    [_ false]))

(define (compiler-driver-state-smoke-type-char?
  [pool : AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast-type-node-pool-state-get pool id)
    [(AstTyChar) true]
    [_ false]))

(define (compiler-driver-state-smoke-cache-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [ok : bool true]
    (begin
      (let
        [enabled-a : CompilerDriverState
          (compiler-driver-state-session-cache-enable state-a)]
        (unless
          (compiler-driver-state-session-cache-enabled? enabled-a)
          (set! ok false)))
      (unless
        (not (compiler-driver-state-session-cache-enabled? state-b))
        (set! ok false))
      (compiler-load-session-cache-disable-for-test!)
      ok)))

(define (compiler-driver-state-smoke-pools-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [expr-a0 : AstExprNodePoolState (struct-get state-a expr-pool)]
    [expr-a-id0 : i64 (ast-expr-node-pool-state-mark expr-a0)]
    [expr-a1 : AstExprNodePoolState
      (compiler-driver-state-smoke-expr-push expr-a0 7)]
    [expr-a-id1 : i64 (ast-expr-node-pool-state-mark expr-a1)]
    [expr-a2 : AstExprNodePoolState
      (compiler-driver-state-smoke-expr-push expr-a1 8)]
    [expr-b0 : AstExprNodePoolState (struct-get state-b expr-pool)]
    [expr-b-mark : i64 (ast-expr-node-pool-state-mark expr-b0)]
    [expr-b1 : AstExprNodePoolState
      (compiler-driver-state-smoke-expr-push expr-b0 11)]
    [expr-b-reset : AstExprNodePoolState
      (ast-expr-node-pool-state-reset-to-mark expr-b1 expr-b-mark)]
    [expr-b-id : i64 (ast-expr-node-pool-state-mark expr-b-reset)]
    [expr-b2 : AstExprNodePoolState
      (compiler-driver-state-smoke-expr-push expr-b-reset 12)]
    [type-a0 : AstTypeNodePoolState (struct-get state-a type-pool)]
    [type-a-id0 : i64 (ast-type-node-pool-state-mark type-a0)]
    [type-a1 : AstTypeNodePoolState
      (compiler-driver-state-smoke-type-push type-a0 (AstTyI64))]
    [type-a-id1 : i64 (ast-type-node-pool-state-mark type-a1)]
    [type-a2 : AstTypeNodePoolState
      (compiler-driver-state-smoke-type-push type-a1 (AstTyString))]
    [type-b0 : AstTypeNodePoolState (struct-get state-b type-pool)]
    [type-b-mark : i64 (ast-type-node-pool-state-mark type-b0)]
    [type-b1 : AstTypeNodePoolState
      (compiler-driver-state-smoke-type-push type-b0 (AstTyBool))]
    [type-b-reset : AstTypeNodePoolState
      (ast-type-node-pool-state-reset-to-mark type-b1 type-b-mark)]
    [type-b-id : i64 (ast-type-node-pool-state-mark type-b-reset)]
    [type-b2 : AstTypeNodePoolState
      (compiler-driver-state-smoke-type-push type-b-reset (AstTyChar))]
    (and
      (= expr-a-id0 0)
      (= expr-a-id1 1)
      (= expr-b-id 0)
      (= (ast-expr-node-pool-state-len expr-a2) 2)
      (= (ast-expr-node-pool-state-len expr-b2) 1)
      (compiler-driver-state-smoke-expr-int? expr-a2 expr-a-id0 7)
      (compiler-driver-state-smoke-expr-int? expr-a2 expr-a-id1 8)
      (compiler-driver-state-smoke-expr-int? expr-b2 expr-b-id 12)
      (= type-a-id0 0)
      (= type-a-id1 1)
      (= type-b-id 0)
      (= (ast-type-node-pool-state-len type-a2) 2)
      (= (ast-type-node-pool-state-len type-b2) 1)
      (compiler-driver-state-smoke-type-i64? type-a2 type-a-id0)
      (compiler-driver-state-smoke-type-char? type-b2 type-b-id))))

(define (main) : i64
  (if (compiler-driver-state-smoke-cache-isolated?)
    (if (compiler-driver-state-smoke-pools-isolated?)
      42
      3)
    2))