;; compiler_ast_types_smoke.tl - Runnable AST data-shape smoke.
(import "../compiler_ast_types.tl")

(define (compiler-ast-state-expr-int-lit?
  [pool : AstExprNodePoolState]
  [id : i64]
  [expected : i64]) : bool
  (match (ast-expr-node-pool-state-get pool id)
    [(AstExpr.Literal lit)
      (match lit
        [(AstLitInt value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-ast-state-type-i64? [pool : AstTypeNodePoolState] [id : i64]) : bool
  (match (ast-type-node-pool-state-get pool id)
    [(AstType.I64) true]
    [_ false]))

(define (compiler-ast-state-type-string?
  [pool : AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast-type-node-pool-state-get pool id)
    [(AstType.String) true]
    [_ false]))

(define (compiler-ast-state-type-char? [pool : AstTypeNodePoolState] [id : i64]) : bool
  (match (ast-type-node-pool-state-get pool id)
    [(AstType.Char) true]
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
      (compiler-ast-state-expr-push-pool a0 (AstExpr.Literal (ast-lit-int 1)))]
    [aid1 : i64 (ast-expr-node-pool-state-mark a1)]
    [a2 : AstExprNodePoolState
      (compiler-ast-state-expr-push-pool a1 (AstExpr.Literal (ast-lit-int 2)))]
    [b0 : AstExprNodePoolState (ast-expr-node-pool-state-create 1)]
    [bmark : i64 (ast-expr-node-pool-state-mark b0)]
    [bid0 : i64 (ast-expr-node-pool-state-mark b0)]
    [b1 : AstExprNodePoolState
      (compiler-ast-state-expr-push-pool b0 (AstExpr.Literal (ast-lit-int 10)))]
    [breset : AstExprNodePoolState
      (ast-expr-node-pool-state-reset-to-mark b1 bmark)]
    [bid1 : i64 (ast-expr-node-pool-state-mark breset)]
    [b2 : AstExprNodePoolState
      (compiler-ast-state-expr-push-pool
        breset
        (AstExpr.Literal (ast-lit-int 11)))]
    [b3 : AstExprNodePoolState
      (ast-expr-node-pool-state-set! b2 bid1 (AstExpr.Literal (ast-lit-int 12)))]
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
      (compiler-ast-state-type-push-pool a0 (AstType.I64))]
    [aid1 : i64 (ast-type-node-pool-state-mark a1)]
    [a2 : AstTypeNodePoolState
      (compiler-ast-state-type-push-pool a1 (AstType.String))]
    [b0 : AstTypeNodePoolState (ast-type-node-pool-state-create 1)]
    [bmark : i64 (ast-type-node-pool-state-mark b0)]
    [bid0 : i64 (ast-type-node-pool-state-mark b0)]
    [b1 : AstTypeNodePoolState
      (compiler-ast-state-type-push-pool b0 (AstType.Bool))]
    [breset : AstTypeNodePoolState
      (ast-type-node-pool-state-reset-to-mark b1 bmark)]
    [bid1 : i64 (ast-type-node-pool-state-mark breset)]
    [b2 : AstTypeNodePoolState
      (compiler-ast-state-type-push-pool breset (AstType.I64))]
    [b3 : AstTypeNodePoolState
      (ast-type-node-pool-state-set! b2 bid1 (AstType.Char))]
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

(define (compiler-ast-state-owned-type-dedup-reuse-smoke?) : bool
  (match (ast-type-node-pool-state-push
    (ast-type-node-pool-state-create 1)
    (AstType.I64))
    [(AstTypeNodePoolPushOk p1 first-id)
      (match (ast-type-node-pool-state-push p1 (AstType.I64))
        [(AstTypeNodePoolPushOk p2 second-id)
          (and
            (= first-id 0)
            (= second-id first-id)
            (= (ast-type-node-pool-state-len p2) 1)
            (compiler-ast-state-type-i64? p2 first-id))])]))

(define (compiler-ast-state-owned-type-dedup-isolated-smoke?) : bool
  (match (ast-type-node-pool-state-push
    (ast-type-node-pool-state-create 1)
    (AstType.I64))
    [(AstTypeNodePoolPushOk a1 a-id)
      (match (ast-type-node-pool-state-push
        (ast-type-node-pool-state-create 1)
        (AstType.I64))
        [(AstTypeNodePoolPushOk b1 b-id)
          (match (ast-type-node-pool-state-push a1 (AstType.I64))
            [(AstTypeNodePoolPushOk a2 a-dupe-id)
              (match (ast-type-node-pool-state-push b1 (AstType.I64))
                [(AstTypeNodePoolPushOk b2 b-dupe-id)
                  (and
                    (= a-id 0)
                    (= b-id 0)
                    (= a-dupe-id a-id)
                    (= b-dupe-id b-id)
                    (= (ast-type-node-pool-state-len a2) 1)
                    (= (ast-type-node-pool-state-len b2) 1)
                    (compiler-ast-state-type-i64? a2 a-id)
                    (compiler-ast-state-type-i64? b2 b-id))])])])]))

(define (compiler-ast-state-owned-type-dedup-reset-smoke?) : bool
  (match (ast-type-node-pool-state-push
    (ast-type-node-pool-state-create 1)
    (AstType.I64))
    [(AstTypeNodePoolPushOk p1 i64-id)
      (match (ast-type-node-pool-state-push p1 (AstType.String))
        [(AstTypeNodePoolPushOk p2 string-id)
          (let
            [reset : AstTypeNodePoolState
              (ast-type-node-pool-state-reset-to-mark p2 1)]
            (match (ast-type-node-pool-state-push reset (AstType.String))
              [(AstTypeNodePoolPushOk p3 string-id2)
                (and
                  (= i64-id 0)
                  (= string-id 1)
                  (= string-id2 1)
                  (= (ast-type-node-pool-state-len p3) 2)
                  (compiler-ast-state-type-i64? p3 i64-id)
                  (compiler-ast-state-type-string? p3 string-id2))]))])]))

(define (compiler-ast-state-owned-node-pools-smoke?) : bool
  (and
    (compiler-ast-state-owned-expr-pool-smoke?)
    (compiler-ast-state-owned-type-pool-smoke?)
    (compiler-ast-state-owned-type-dedup-reuse-smoke?)
    (compiler-ast-state-owned-type-dedup-isolated-smoke?)
    (compiler-ast-state-owned-type-dedup-reset-smoke?)))

(define (compiler-ast-context-expr-int-lit?
  [pools : AstNodePoolContext]
  [id : i64]
  [expected : i64]) : bool
  (match (ast-node-pool-context-expr-get pools id)
    [(AstExpr.Literal lit)
      (match lit
        [(AstLitInt value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-ast-context-shared-binary?
  [pools : AstNodePoolContext]
  [id : i64]
  [old-lit : i64]
  [old-span : i64]) : bool
  (match (ast-node-pool-context-expr-get pools id)
    [(AstExpr.Binary _ left right)
      (if (= left right)
        (match (ast-node-pool-context-expr-get pools left)
          [(AstExpr.Spanned inner span)
            (and
              (not (= left old-span))
              (not (= inner old-lit))
              (= (struct-get span start-line) 1)
              (= (struct-get span start-col) 2)
              (= (struct-get span end-line) 3)
              (= (struct-get span end-col) 4)
              (compiler-ast-context-expr-int-lit? pools inner 7))]
          [_ false])
        false)]
    [_ false]))

(define (compiler-ast-global-shared-binary? [id : i64] [ptr-ty-id : i64]) : bool
  (and
    (match (ast-node-get id)
      [(AstExpr.Binary _ left right)
        (if (= left right)
          (match (ast-node-get left)
            [(AstExpr.Spanned inner _)
              (match (ast-node-get inner)
                [(AstExpr.Literal lit)
                  (match lit
                    [(AstLitInt value _) (= value 7)]
                    [_ false])]
                [_ false])]
            [_ false])
          false)]
      [_ false])
    (match (ty-node-get ptr-ty-id)
      [(AstType.Ptr inner)
        (match (ty-node-get inner)
          [(AstType.I64) true]
          [_ false])]
      [_ false])))

(define (compiler-ast-compaction-program-shape-ok?
  [pools : AstNodePoolContext]
  [program : AstProgram]
  [source-body : i64]
  [source-lit : i64]
  [source-span : i64]) : bool
  (match program
    [(AstProgram.Program decls-box)
      (match (box-get decls-box)
        [(AstDeclList.Cons first rest-box)
          (match first
            [(AstDecl.Def _ maybe-ty first-body)
              (match (box-get rest-box)
                [(AstDeclList.Cons second tail-box)
                  (match second
                    [(AstDecl.Test _ second-body _)
                      (and
                        (= first-body second-body)
                        (not (= first-body source-body))
                        (= (ast-node-pool-context-expr-len pools) 3)
                        (= (ast-node-pool-context-type-len pools) 2)
                        (compiler-ast-context-shared-binary?
                          pools
                          first-body
                          source-lit
                          source-span)
                        (match maybe-ty
                          [(AstMaybeType.Some ty)
                            (match ty
                              [(AstType.Array ptr-id count)
                                (and
                                  (= count 4)
                                  (match (ast-node-pool-context-type-get
                                    pools
                                    ptr-id)
                                    [(AstType.Ptr inner)
                                      (match (ast-node-pool-context-type-get
                                        pools
                                        inner)
                                        [(AstType.I64) true]
                                        [_ false])]
                                    [_ false]))]
                              [_ false])]
                          [_ false])
                        (match (box-get tail-box)
                          [(AstDeclList.Nil) true]
                          [_ false]))]
                    [_ false])]
                [_ false])]
            [_ false])]
        [_ false])]))

(define (compiler-ast-program-compaction-smoke?) : bool
  (let
    [source-pools : AstNodePoolContext
      (ast-node-pool-context-new
        (ast-expr-node-pool-state-create 8)
        (ast-type-node-pool-state-create 8))]
    [dest-pools : AstNodePoolContext
      (ast-node-pool-context-new
        (ast-expr-node-pool-state-create 8)
        (ast-type-node-pool-state-create 8))]
    [active-before : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [source-decoy-expr : i64
      (ast-node-pool-context-expr-push
        source-pools
        (AstExpr.Literal (ast-lit-int 999)))]
    [source-decoy-ty : i64
      (ast-node-pool-context-type-push source-pools (AstType.Char))]
    [source-i64-ty : i64
      (ast-node-pool-context-type-push source-pools (AstType.I64))]
    [source-ptr-ty : i64
      (ast-node-pool-context-type-push source-pools (AstType.Ptr source-i64-ty))]
    [array-ty : AstType (AstType.Array source-ptr-ty 4)]
    [source-lit : i64
      (ast-node-pool-context-expr-push
        source-pools
        (AstExpr.Literal (ast-lit-int 7)))]
    [source-span : i64
      (ast-node-pool-context-expr-push
        source-pools
        (AstExpr.Spanned source-lit (AstSourceSpan 1 2 3 4)))]
    [source-body : i64
      (ast-node-pool-context-expr-push
        source-pools
        (AstExpr.Binary (AstBinAdd) source-span source-span))]
    [program : AstProgram
      (ast-program
        (ast-decl-cons
          (ast-decl-def "value" (AstMaybeType.Some array-ty) source-body)
          (ast-decl-cons
            (ast-decl-test "same" source-body (AstSourceSpan 5 6 7 8))
            AstDeclList.Nil)))]
    [dest-decoy-expr : i64
      (ast-node-pool-context-expr-push
        dest-pools
        (AstExpr.Literal (ast-lit-int 1234)))]
    [dest-decoy-ty : i64
      (ast-node-pool-context-type-push dest-pools (AstType.Bool))]
    [compacted : AstProgramCompaction
      (ast-program-compact-with-pools source-pools dest-pools program)]
    (match compacted
      [(AstProgramCompaction out-program out-pools)
        (let
          [shape-ok : bool
            (and
              (= source-decoy-expr 0)
              (= source-decoy-ty 0)
              (= dest-decoy-expr 0)
              (= dest-decoy-ty 0)
              (compiler-ast-compaction-program-shape-ok?
                out-pools
                out-program
                source-body
                source-lit
                source-span))]
          [installed-ok : bool
            (match out-program
              [(AstProgram.Program decls-box)
                (match (box-get decls-box)
                  [(AstDeclList.Cons first _)
                    (match first
                      [(AstDecl.Def _ maybe-ty body)
                        (match maybe-ty
                          [(AstMaybeType.Some ty)
                            (match ty
                              [(AstType.Array ptr-id _)
                                (begin
                                  (ast-node-pool-context-install! out-pools)
                                  (compiler-ast-global-shared-binary?
                                    body
                                    ptr-id))]
                              [_ false])]
                          [_ false])]
                      [_ false])]
                  [_ false])])]
          (begin
            (ast-node-pool-context-install! active-before)
            (and shape-ok installed-ok)))])))

(define (main) : i64
  (if (and
    (= (compiler-ast-smoke) 23)
    (compiler-ast-state-owned-node-pools-smoke?)
    (compiler-ast-program-compaction-smoke?))
    42
    1))