;; compiler_ast_types_smoke.tl - Runnable AST data-shape smoke.
(import "compiler_ast_types.tl")

(define (compiler-ast-state-expr-int-lit?
  [pool : AstExprNodePoolState]
  [id : i64]
  [expected : i64]) : bool
  (match (ast-expr-node-pool-state-get pool id)
    [(AstExprLiteral lit)
      (match lit
        [(AstLitInt value) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-ast-state-type-i64? [pool : AstTypeNodePoolState] [id : i64]) : bool
  (match (ast-type-node-pool-state-get pool id)
    [(AstTyI64) true]
    [_ false]))

(define (compiler-ast-state-type-string?
  [pool : AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast-type-node-pool-state-get pool id)
    [(AstTyString) true]
    [_ false]))

(define (compiler-ast-state-type-char? [pool : AstTypeNodePoolState] [id : i64]) : bool
  (match (ast-type-node-pool-state-get pool id)
    [(AstTyChar) true]
    [_ false]))

(define (compiler-ast-state-expr-push-pool
  [pool : AstExprNodePoolState]
  [node : AstExpr]) : AstExprNodePoolState
  (match (ast-expr-node-pool-state-push pool node)
    [(AstExprNodePoolPushOk next _) next]))

(define (compiler-ast-state-type-push-pool
  [pool : AstTypeNodePoolState]
  [node : AstType]) : AstTypeNodePoolState
  (match (ast-type-node-pool-state-push pool node)
    [(AstTypeNodePoolPushOk next _) next]))

(define (compiler-ast-state-owned-expr-pool-smoke?) : bool
  (let
    [a0 : AstExprNodePoolState (ast-expr-node-pool-state-create 1)]
    [aid0 : i64 (ast-expr-node-pool-state-mark a0)]
    [a1 : AstExprNodePoolState
      (compiler-ast-state-expr-push-pool a0 (AstExprLiteral (AstLitInt 1)))]
    [aid1 : i64 (ast-expr-node-pool-state-mark a1)]
    [a2 : AstExprNodePoolState
      (compiler-ast-state-expr-push-pool a1 (AstExprLiteral (AstLitInt 2)))]
    [b0 : AstExprNodePoolState (ast-expr-node-pool-state-create 1)]
    [bmark : i64 (ast-expr-node-pool-state-mark b0)]
    [bid0 : i64 (ast-expr-node-pool-state-mark b0)]
    [b1 : AstExprNodePoolState
      (compiler-ast-state-expr-push-pool b0 (AstExprLiteral (AstLitInt 10)))]
    [breset : AstExprNodePoolState
      (ast-expr-node-pool-state-reset-to-mark b1 bmark)]
    [bid1 : i64 (ast-expr-node-pool-state-mark breset)]
    [b2 : AstExprNodePoolState
      (compiler-ast-state-expr-push-pool breset (AstExprLiteral (AstLitInt 11)))]
    [b3 : AstExprNodePoolState
      (ast-expr-node-pool-state-set! b2 bid1 (AstExprLiteral (AstLitInt 12)))]
    (and
      (= aid0 0)
      (= aid1 1)
      (= bid0 0)
      (= bid1 0)
      (= (ast-expr-node-pool-state-len a2) 2)
      (= (ast-expr-node-pool-state-len b3) 1)
      (compiler-ast-state-expr-int-lit? a2 aid0 1)
      (compiler-ast-state-expr-int-lit? a2 aid1 2)
      (compiler-ast-state-expr-int-lit? b3 bid1 12))))

(define (compiler-ast-state-owned-type-pool-smoke?) : bool
  (let
    [a0 : AstTypeNodePoolState (ast-type-node-pool-state-create 1)]
    [aid0 : i64 (ast-type-node-pool-state-mark a0)]
    [a1 : AstTypeNodePoolState
      (compiler-ast-state-type-push-pool a0 (AstTyI64))]
    [aid1 : i64 (ast-type-node-pool-state-mark a1)]
    [a2 : AstTypeNodePoolState
      (compiler-ast-state-type-push-pool a1 (AstTyString))]
    [b0 : AstTypeNodePoolState (ast-type-node-pool-state-create 1)]
    [bmark : i64 (ast-type-node-pool-state-mark b0)]
    [bid0 : i64 (ast-type-node-pool-state-mark b0)]
    [b1 : AstTypeNodePoolState
      (compiler-ast-state-type-push-pool b0 (AstTyBool))]
    [breset : AstTypeNodePoolState
      (ast-type-node-pool-state-reset-to-mark b1 bmark)]
    [bid1 : i64 (ast-type-node-pool-state-mark breset)]
    [b2 : AstTypeNodePoolState
      (compiler-ast-state-type-push-pool breset (AstTyI64))]
    [b3 : AstTypeNodePoolState
      (ast-type-node-pool-state-set! b2 bid1 (AstTyChar))]
    (and
      (= aid0 0)
      (= aid1 1)
      (= bid0 0)
      (= bid1 0)
      (= (ast-type-node-pool-state-len a2) 2)
      (= (ast-type-node-pool-state-len b3) 1)
      (not (ast-type-node-pool-state-exhausted? a2))
      (compiler-ast-state-type-i64? a2 aid0)
      (compiler-ast-state-type-string? a2 aid1)
      (compiler-ast-state-type-char? b3 bid1))))

(define (compiler-ast-state-owned-node-pools-smoke?) : bool
  (and
    (compiler-ast-state-owned-expr-pool-smoke?)
    (compiler-ast-state-owned-type-pool-smoke?)))

(define (main) : i64
  (if (and
    (= (compiler-ast-smoke) 23)
    (compiler-ast-state-owned-node-pools-smoke?))
    42
    1))