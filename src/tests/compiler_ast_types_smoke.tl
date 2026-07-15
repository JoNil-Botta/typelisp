;; compiler_ast_types_smoke.tl - Runnable AST data-shape smoke.
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import stdlib.string)

(define (compiler-ast-state-expr-int-lit?
  [pool : ast.AstExprNodePoolState]
  [id : i64]
  [expected : i64]) : bool
  (match (ast.ast-expr-node-pool-state-get pool id)
    [(ast.AstExpr.Literal lit)
      (match lit
        [(ast.AstLiteral.Int value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-ast-state-type-i64?
  [pool : ast.AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast.ast-type-node-pool-state-get pool id)
    [(ast.AstType.I64) true]
    [_ false]))

(define (compiler-ast-state-type-string?
  [pool : ast.AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast.ast-type-node-pool-state-get pool id)
    [(ast.AstType.String) true]
    [_ false]))

(define (compiler-ast-state-type-char?
  [pool : ast.AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast.ast-type-node-pool-state-get pool id)
    [(ast.AstType.Char) true]
    [_ false]))

(define (compiler-ast-state-expr-push-pool
  [pool : ast.AstExprNodePoolState]
  [node : ast.AstExpr]) : ast.AstExprNodePoolState
  (match (ast.ast-expr-node-pool-state-push pool node)
    [(ast.AstExprNodePoolPushOk next _) next]))

(define (compiler-ast-state-type-push-pool
  [pool : ast.AstTypeNodePoolState]
  [node : ast.AstType]) : ast.AstTypeNodePoolState
  (match (ast.ast-type-node-pool-state-push pool node)
    [(ast.AstTypeNodePoolPushOk next _) next]))

(define (compiler-ast-state-owned-expr-pool-smoke?) : bool
  (let
    [a0 : ast.AstExprNodePoolState (ast.ast-expr-node-pool-state-create 1)]
    [aid0 : i64 (ast.ast-expr-node-pool-state-mark a0)]
    [a1 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool
        a0
        (ast.AstExpr.Literal (ast.ast-lit-int 1)))]
    [aid1 : i64 (ast.ast-expr-node-pool-state-mark a1)]
    [a2 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool
        a1
        (ast.AstExpr.Literal (ast.ast-lit-int 2)))]
    [b0 : ast.AstExprNodePoolState (ast.ast-expr-node-pool-state-create 1)]
    [bmark : i64 (ast.ast-expr-node-pool-state-mark b0)]
    [bid0 : i64 (ast.ast-expr-node-pool-state-mark b0)]
    [b1 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool
        b0
        (ast.AstExpr.Literal (ast.ast-lit-int 10)))]
    [breset : ast.AstExprNodePoolState
      (ast.ast-expr-node-pool-state-reset-to-mark b1 bmark)]
    [bid1 : i64 (ast.ast-expr-node-pool-state-mark breset)]
    [b2 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool
        breset
        (ast.AstExpr.Literal (ast.ast-lit-int 11)))]
    [b3 : ast.AstExprNodePoolState
      (ast.ast-expr-node-pool-state-set!
        b2
        bid1
        (ast.AstExpr.Literal (ast.ast-lit-int 12)))]
    (and
      (= aid0 0)
      (= aid1 1)
      (= bid0 0)
      (= bid1 0)
      (= (ast.ast-expr-node-pool-state-len a2) 2)
      (= (ast.ast-expr-node-pool-state-len b3) 1)
      (compiler-ast-state-expr-int-lit? a2 aid0 1)
      (compiler-ast-state-expr-int-lit? a2 aid1 2)
      (compiler-ast-state-expr-int-lit? b3 bid1 12))))

(define (compiler-ast-state-owned-type-pool-smoke?) : bool
  (let
    [a0 : ast.AstTypeNodePoolState (ast.ast-type-node-pool-state-create 1)]
    [aid0 : i64 (ast.ast-type-node-pool-state-mark a0)]
    [a1 : ast.AstTypeNodePoolState
      (compiler-ast-state-type-push-pool a0 (ast.AstType.I64))]
    [aid1 : i64 (ast.ast-type-node-pool-state-mark a1)]
    [a2 : ast.AstTypeNodePoolState
      (compiler-ast-state-type-push-pool a1 (ast.AstType.String))]
    [b0 : ast.AstTypeNodePoolState (ast.ast-type-node-pool-state-create 1)]
    [bmark : i64 (ast.ast-type-node-pool-state-mark b0)]
    [bid0 : i64 (ast.ast-type-node-pool-state-mark b0)]
    [b1 : ast.AstTypeNodePoolState
      (compiler-ast-state-type-push-pool b0 (ast.AstType.Bool))]
    [breset : ast.AstTypeNodePoolState
      (ast.ast-type-node-pool-state-reset-to-mark b1 bmark)]
    [bid1 : i64 (ast.ast-type-node-pool-state-mark breset)]
    [b2 : ast.AstTypeNodePoolState
      (compiler-ast-state-type-push-pool breset (ast.AstType.I64))]
    [b3 : ast.AstTypeNodePoolState
      (ast.ast-type-node-pool-state-set! b2 bid1 (ast.AstType.Char))]
    (and
      (= aid0 0)
      (= aid1 1)
      (= bid0 0)
      (= bid1 0)
      (= (ast.ast-type-node-pool-state-len a2) 2)
      (= (ast.ast-type-node-pool-state-len b3) 1)
      (not (ast.ast-type-node-pool-state-exhausted? a2))
      (compiler-ast-state-type-i64? a2 aid0)
      (compiler-ast-state-type-string? a2 aid1)
      (compiler-ast-state-type-char? b3 bid1))))

(define (compiler-ast-state-owned-type-dedup-reuse-smoke?) : bool
  (match (ast.ast-type-node-pool-state-push
    (ast.ast-type-node-pool-state-create 1)
    (ast.AstType.I64))
    [(ast.AstTypeNodePoolPushOk p1 first-id)
      (match (ast.ast-type-node-pool-state-push p1 (ast.AstType.I64))
        [(ast.AstTypeNodePoolPushOk p2 second-id)
          (and
            (= first-id 0)
            (= second-id first-id)
            (= (ast.ast-type-node-pool-state-len p2) 1)
            (compiler-ast-state-type-i64? p2 first-id))])]))

(define (compiler-ast-state-owned-type-dedup-isolated-smoke?) : bool
  (match (ast.ast-type-node-pool-state-push
    (ast.ast-type-node-pool-state-create 1)
    (ast.AstType.I64))
    [(ast.AstTypeNodePoolPushOk a1 a-id)
      (match (ast.ast-type-node-pool-state-push
        (ast.ast-type-node-pool-state-create 1)
        (ast.AstType.I64))
        [(ast.AstTypeNodePoolPushOk b1 b-id)
          (match (ast.ast-type-node-pool-state-push a1 (ast.AstType.I64))
            [(ast.AstTypeNodePoolPushOk a2 a-dupe-id)
              (match (ast.ast-type-node-pool-state-push b1 (ast.AstType.I64))
                [(ast.AstTypeNodePoolPushOk b2 b-dupe-id)
                  (and
                    (= a-id 0)
                    (= b-id 0)
                    (= a-dupe-id a-id)
                    (= b-dupe-id b-id)
                    (= (ast.ast-type-node-pool-state-len a2) 1)
                    (= (ast.ast-type-node-pool-state-len b2) 1)
                    (compiler-ast-state-type-i64? a2 a-id)
                    (compiler-ast-state-type-i64? b2 b-id))])])])]))

(define (compiler-ast-state-owned-type-dedup-reset-smoke?) : bool
  (match (ast.ast-type-node-pool-state-push
    (ast.ast-type-node-pool-state-create 1)
    (ast.AstType.I64))
    [(ast.AstTypeNodePoolPushOk p1 i64-id)
      (match (ast.ast-type-node-pool-state-push p1 (ast.AstType.String))
        [(ast.AstTypeNodePoolPushOk p2 string-id)
          (let
            [reset : ast.AstTypeNodePoolState
              (ast.ast-type-node-pool-state-reset-to-mark p2 1)]
            (match (ast.ast-type-node-pool-state-push
              reset
              (ast.AstType.String))
              [(ast.AstTypeNodePoolPushOk p3 string-id2)
                (and
                  (= i64-id 0)
                  (= string-id 1)
                  (= string-id2 1)
                  (= (ast.ast-type-node-pool-state-len p3) 2)
                  (compiler-ast-state-type-i64? p3 i64-id)
                  (compiler-ast-state-type-string? p3 string-id2))]))])]))

(define (compiler-ast-state-owned-node-pools-smoke?) : bool
  (and
    (compiler-ast-state-owned-expr-pool-smoke?)
    (compiler-ast-state-owned-type-pool-smoke?)
    (compiler-ast-state-owned-type-dedup-reuse-smoke?)
    (compiler-ast-state-owned-type-dedup-isolated-smoke?)
    (compiler-ast-state-owned-type-dedup-reset-smoke?)))

(define (compiler-ast-context-type-i64?
  [pools : ast.AstNodePoolContext]
  [id : i64]) : bool
  (match (ast.ast-node-pool-context-type-get pools id)
    [(ast.AstType.I64) true]
    [_ false]))

(define (compiler-ast-context-type-char?
  [pools : ast.AstNodePoolContext]
  [id : i64]) : bool
  (match (ast.ast-node-pool-context-type-get pools id)
    [(ast.AstType.Char) true]
    [_ false]))

(define (compiler-ast-context-expr-int-lit?
  [pools : ast.AstNodePoolContext]
  [id : i64]
  [expected : i64]) : bool
  (match (ast.ast-node-pool-context-expr-get pools id)
    [(ast.AstExpr.Literal lit)
      (match lit
        [(ast.AstLiteral.Int value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-ast-context-base-arenas-match?
  [pools : ast.AstNodePoolContext]) : bool
  (let
    [expr-pool : ast.AstExprNodePoolState
      (array-ref (struct-get pools expr-pool) 0)]
    [type-pool : ast.AstTypeNodePoolState
      (array-ref (struct-get pools type-pool) 0)]
    (= (struct-get expr-pool base-arena) (struct-get type-pool base-arena))))

(define (compiler-ast-context-clone-types-only-smoke?) : bool
  (let
    [source : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [expr-id : i64
      (ast.ast-node-pool-context-expr-push
        source
        (ast.AstExpr.Literal (ast.ast-lit-int 17)))]
    [i64-id : i64
      (ast.ast-node-pool-context-type-push source (ast.AstType.I64))]
    [ptr-id : i64
      (ast.ast-node-pool-context-type-push source (ast.AstType.Ptr i64-id))]
    [ptr-dupe-id : i64
      (ast.ast-node-pool-context-type-push source (ast.AstType.Ptr i64-id))]
    [cloned : ast.AstNodePoolContext
      (ast.ast-node-pool-context-clone-types-only source)]
    [cloned-ptr-id : i64
      (ast.ast-node-pool-context-type-push cloned (ast.AstType.Ptr i64-id))]
    (and
      (= expr-id 0)
      (= i64-id 0)
      (= ptr-id 1)
      (= ptr-dupe-id ptr-id)
      (= cloned-ptr-id ptr-id)
      (= (ast.ast-node-pool-context-expr-len cloned) 0)
      (= (ast.ast-node-pool-context-type-len cloned) 2)
      (compiler-ast-context-type-i64? cloned i64-id)
      (match (ast.ast-node-pool-context-type-get cloned ptr-id)
        [(ast.AstType.Ptr inner) (= inner i64-id)]
        [_ false]))))

(define (compiler-ast-active-context-sync-smoke?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [ok : bool true]
    (begin
      (ast.ast-node-pool-context-install! pools)
      (let
        [expr-a : i64
          (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 31)))]
        [expr-b : i64
          (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 32)))]
        [type-a : i64 (ast.ty-node-push (ast.AstType.I64))]
        [type-b : i64 (ast.ty-node-push (ast.AstType.Char))]
        (begin
          (unless (= expr-a 0) (set! ok false))
          (unless (= expr-b 1) (set! ok false))
          (unless (= type-a 0) (set! ok false))
          (unless (= type-b 1) (set! ok false))
          (unless
            (= (ast.ast-node-pool-context-expr-len pools) 2)
            (set! ok false))
          (unless
            (= (ast.ast-node-pool-context-type-len pools) 2)
            (set! ok false))
          (unless
            (compiler-ast-context-expr-int-lit? pools expr-a 31)
            (set! ok false))
          (unless
            (compiler-ast-context-expr-int-lit? pools expr-b 32)
            (set! ok false))
          (unless (compiler-ast-context-type-i64? pools type-a) (set! ok false))
          (unless
            (compiler-ast-context-type-char? pools type-b)
            (set! ok false))
          (unless
            (compiler-ast-context-base-arenas-match? pools)
            (set! ok false))
          (ast.ast-node-pool-truncate! 1)
          (ast.ty-node-pool-truncate! 1)
          (unless
            (= (ast.ast-node-pool-context-expr-len pools) 1)
            (set! ok false))
          (unless
            (= (ast.ast-node-pool-context-type-len pools) 1)
            (set! ok false))
          (unless
            (compiler-ast-context-expr-int-lit? pools expr-a 31)
            (set! ok false))
          (unless (compiler-ast-context-type-i64? pools type-a) (set! ok false))
          (ast.ast-node-pool-context-install! active-before)
          ok)))))

(define (compiler-ast-context-shared-binary?
  [pools : ast.AstNodePoolContext]
  [id : i64]
  [old-lit : i64]
  [old-span : i64]) : bool
  (match (ast.ast-node-pool-context-expr-get pools id)
    [(ast.AstExpr.Binary _ left right)
      (if (= left right)
        (match (ast.ast-node-pool-context-expr-get pools left)
          [(ast.AstExpr.Spanned inner span)
            (and
              (not (= left old-span))
              (not (= inner old-lit))
              (= (ast.ast-source-span-start-line span) 1)
              (= (ast.ast-source-span-start-col span) 2)
              (= (ast.ast-source-span-end-line span) 3)
              (= (ast.ast-source-span-end-col span) 4)
              (compiler-ast-context-expr-int-lit? pools inner 7))]
          [_ false])
        false)]
    [_ false]))

(define (compiler-ast-global-shared-binary? [id : i64] [ptr-ty-id : i64]) : bool
  (and
    (match (ast.ast-node-get id)
      [(ast.AstExpr.Binary _ left right)
        (if (= left right)
          (match (ast.ast-node-get left)
            [(ast.AstExpr.Spanned inner _)
              (match (ast.ast-node-get inner)
                [(ast.AstExpr.Literal lit)
                  (match lit
                    [(ast.AstLiteral.Int value _) (= value 7)]
                    [_ false])]
                [_ false])]
            [_ false])
          false)]
      [_ false])
    (match (ast.ty-node-get ptr-ty-id)
      [(ast.AstType.Ptr inner)
        (match (ast.ty-node-get inner)
          [(ast.AstType.I64) true]
          [_ false])]
      [_ false])))

(define (compiler-ast-compaction-program-shape-ok?
  [pools : ast.AstNodePoolContext]
  [program : ast.AstProgram]
  [source-body : i64]
  [source-lit : i64]
  [source-span : i64]
  [source-make : i64]) : bool
  (match program
    [(ast.AstProgram.Program decls-box)
      (match (ast.ast-decl-list-step (box-get decls-box))
        [(ast.AstDeclListStep.Cons first rest-box)
          (match first
            [(ast.AstDecl.Def _ maybe-ty first-body)
              (match (ast.ast-decl-list-step rest-box)
                [(ast.AstDeclListStep.Cons second tail-box)
                  (match second
                    [(ast.AstDecl.Test _ second-body _)
                      (and
                        (= first-body second-body)
                        (not (= first-body source-body))
                        (= (ast.ast-node-pool-context-expr-len pools) 4)
                        (= (ast.ast-node-pool-context-type-len pools) 2)
                        (compiler-ast-context-shared-binary?
                          pools
                          first-body
                          source-lit
                          source-span)
                        (match maybe-ty
                          [(ast.AstMaybeType.Some ty)
                            (match ty
                              [(ast.AstType.Array ptr-id count)
                                (and
                                  (= count 4)
                                  (match (ast.ast-node-pool-context-type-get
                                    pools
                                    ptr-id)
                                    [(ast.AstType.Ptr inner)
                                      (match (ast.ast-node-pool-context-type-get
                                        pools
                                        inner)
                                        [(ast.AstType.I64) true]
                                        [_ false])]
                                    [_ false]))]
                              [_ false])]
                          [_ false])
                        (match (ast.ast-decl-list-step tail-box)
                          [(ast.AstDeclListStep.Cons third final-box)
                            (match third
                              [(ast.AstDecl.Def _ _ make-body)
                                (and
                                  (not (= make-body source-make))
                                  (match (ast.ast-node-pool-context-expr-get
                                    pools
                                    make-body)
                                    [(ast.AstExpr.MakeArray _ size-body)
                                      (= size-body first-body)]
                                    [_ false])
                                  (match (ast.ast-decl-list-step final-box)
                                    [(ast.AstDeclListStep.Nil) true]
                                    [_ false]))]
                              [_ false])]
                          [_ false]))]
                    [_ false])]
                [_ false])]
            [_ false])]
        [_ false])]))

(define (compiler-ast-program-compaction-smoke?) : bool
  (let
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8))]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8))]
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [source-decoy-expr : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Literal (ast.ast-lit-int 999)))]
    [source-decoy-ty : i64
      (ast.ast-node-pool-context-type-push source-pools (ast.AstType.Char))]
    [source-i64-ty : i64
      (ast.ast-node-pool-context-type-push source-pools (ast.AstType.I64))]
    [source-ptr-ty : i64
      (ast.ast-node-pool-context-type-push
        source-pools
        (ast.AstType.Ptr source-i64-ty))]
    [array-ty : ast.AstType (ast.AstType.Array source-ptr-ty 4)]
    [source-lit : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Literal (ast.ast-lit-int 7)))]
    [source-span : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Spanned source-lit (ast.ast-source-span 1 2 3 4)))]
    [source-body : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Binary (ast.AstBinOp.Add) source-span source-span))]
    [source-make : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.MakeArray (ast.AstType.Ptr source-i64-ty) source-body))]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-def
            "value"
            (ast.AstMaybeType.Some array-ty)
            source-body)
          (ast.ast-decl-cons
            (ast.ast-decl-test "same" source-body (ast.ast-source-span 5 6 7 8))
            (ast.ast-decl-cons
              (ast.ast-decl-def "array" ast.AstMaybeType.No source-make)
              (ast.ast-decl-list-new)))))]
    [dest-decoy-expr : i64
      (ast.ast-node-pool-context-expr-push
        dest-pools
        (ast.AstExpr.Literal (ast.ast-lit-int 1234)))]
    [dest-decoy-ty : i64
      (ast.ast-node-pool-context-type-push dest-pools (ast.AstType.Bool))]
    [compacted : ast.AstProgramCompaction
      (ast.ast-program-compact-with-pools source-pools dest-pools program)]
    (match compacted
      [(ast.AstProgramCompaction out-program out-pools)
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
                source-span
                source-make))]
          [installed-ok : bool
            (match out-program
              [(ast.AstProgram.Program decls-box)
                (match (ast.ast-decl-list-step (box-get decls-box))
                  [(ast.AstDeclListStep.Cons first _)
                    (match first
                      [(ast.AstDecl.Def _ maybe-ty body)
                        (match maybe-ty
                          [(ast.AstMaybeType.Some ty)
                            (match ty
                              [(ast.AstType.Array ptr-id _)
                                (begin
                                  (ast.ast-node-pool-context-install! out-pools)
                                  (compiler-ast-global-shared-binary?
                                    body
                                    ptr-id))]
                              [_ false])]
                          [_ false])]
                      [_ false])]
                  [_ false])])]
          (begin
            (ast.ast-node-pool-context-install! active-before)
            (and shape-ok installed-ok)))])))

(define (compiler-ast-program-copy-append-smoke?) : bool
  (let
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 4)]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 4)]
    [_dest-expr : i64
      (ast.ast-node-pool-context-expr-push
        dest-pools
        (ast.AstExpr.Literal (ast.ast-lit-int 111)))]
    [_dest-type : i64
      (ast.ast-node-pool-context-type-push dest-pools (ast.AstType.Bool))]
    [_source-decoy : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Literal (ast.ast-lit-int 999)))]
    [source-expr : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Literal (ast.ast-lit-int 222)))]
    [source-type : i64
      (ast.ast-node-pool-context-type-push source-pools (ast.AstType.I64))]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-def
            "appended"
            (ast.AstMaybeType.Some (ast.AstType.Ptr source-type))
            source-expr)
          (ast.ast-decl-list-new)))]
    [copied : ast.AstProgramCompaction
      (ast.ast-program-copy-append-with-pools source-pools dest-pools program)]
    (match copied
      [(ast.AstProgramCompaction out-program out-pools)
        (and
          (= (ast.ast-node-pool-context-expr-len out-pools) 2)
          (= (ast.ast-node-pool-context-type-len out-pools) 2)
          (compiler-ast-context-expr-int-lit? out-pools 0 111)
          (match out-program
            [(ast.AstProgram.Program decls-box)
              (match (ast.ast-decl-list-step (box-get decls-box))
                [(ast.AstDeclListStep.Cons decl rest)
                  (match decl
                    [(ast.AstDecl.Def _ maybe-type body)
                      (and
                        (compiler-ast-context-expr-int-lit? out-pools body 222)
                        (match maybe-type
                          [(ast.AstMaybeType.Some (ast.AstType.Ptr inner))
                            (compiler-ast-context-type-i64? out-pools inner)]
                          [_ false])
                        (match (ast.ast-decl-list-step rest)
                          [(ast.AstDeclListStep.Nil) true]
                          [_ false]))]
                    [_ false])]
                [_ false])]))])))

(define (compiler-ast-compaction-string-def-ok?
  [pools : ast.AstNodePoolContext]
  [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Def _ maybe-ty value)
      (and
        (match maybe-ty
          [(ast.AstMaybeType.Some ty)
            (match ty
              [(ast.AstType.Ref region inner)
                (and
                  (string.eq region "borrowed")
                  (match (ast.ast-node-pool-context-type-get pools inner)
                    [(ast.AstType.I64) true]
                    [_ false]))]
              [_ false])]
          [_ false])
        (match (ast.ast-node-pool-context-expr-get pools value)
          [(ast.AstExpr.Literal (ast.AstLiteral.String text))
            (string.eq text "hello")]
          [_ false]))]
    [_ false]))

(define (compiler-ast-compaction-binary-def-ok?
  [pools : ast.AstNodePoolContext]
  [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Def _ ast.AstMaybeType.No value)
      (match (ast.ast-node-pool-context-expr-get pools value)
        [(ast.AstExpr.BinaryData text) (string.eq text "bytes")]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-import-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Import
        (ast.AstImportSpec.Spec
          (ast.AstImportKind.Path)
          path
          module-name
          alias
          _))
      (and
        (string.eq path "pkg/path")
        (match module-name
          [(ast.AstMaybeModuleName.Some name) (string.eq name "pkg.module")]
          [_ false])
        (match alias
          [(ast.AstMaybeImportAlias.Some name) (string.eq name "pkg")]
          [_ false]))]
    [_ false]))

(define (compiler-ast-compaction-macro-call-ok?
  [pools : ast.AstNodePoolContext]
  [call : i64]) : bool
  (match (ast.ast-node-pool-context-expr-get pools call)
    [(ast.AstExpr.Call func args)
      (and
        (match (ast.ast-node-pool-context-expr-get pools func)
          [(ast.AstExpr.Var _) true]
          [_ false])
        (= (ast.ast-expr-list-len (& args)) 1))]
    [_ false]))

(define (compiler-ast-compaction-macro-import-ok?
  [pools : ast.AstNodePoolContext]
  [decl : ast.AstDecl]
  [decls-kind? : bool]) : bool
  (match decl
    [(ast.AstDecl.Import (ast.AstImportSpec.Spec kind _ _ _ _))
      (match kind
        [(ast.AstImportKind.Macro call _)
          (and
            (not decls-kind?)
            (compiler-ast-compaction-macro-call-ok? pools call))]
        [(ast.AstImportKind.MacroDecls call _)
          (and decls-kind? (compiler-ast-compaction-macro-call-ok? pools call))]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-extern-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Extern _ _ metadata _)
      (match (box-get metadata)
        [(ast.AstExternMetadata.Metadata (ast.AstExternAbi.C) symbol links true)
          (and
            (string.eq symbol "native_symbol")
            (match (ast.ast-extern-link-input-list-get
              (& links)
              0
              (ast.ast-extern-link-input-fallback))
              [(ast.AstExternLinkInput.Lib name) (string.eq name "m")]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-dispatch-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.DefDispatch _ variants)
      (match (ast.ast-dispatch-variant-list-get
        (& variants)
        0
        (ast.ast-dispatch-variant-fallback))
        [(ast.AstDispatchVariant.Variant (ast.AstDispatchIsa.Avx2) name)
          (string.eq name "fast")]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-lifetimes-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.DefStructLifetimes _ lifetimes _ _ _)
      (string.eq (ast.ast-lifetime-list-get (& lifetimes) 0 "") "owner")]
    [_ false]))

(define (compiler-ast-compaction-include-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.IncludeStr name path)
      (and (string.eq name "inc") (string.eq path "data.txt"))]
    [_ false]))

(define (compiler-ast-program-compaction-string-payloads-smoke?) : bool
  (let
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8))]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8))]
    [source-i64-ty : i64
      (ast.ast-node-pool-context-type-push source-pools (ast.AstType.I64))]
    [_source-decoy : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Literal (ast.ast-lit-int 999)))]
    [text-expr : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Literal (ast.AstLiteral.String "hello")))]
    [binary-expr : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.BinaryData "bytes"))]
    [macro-func : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Var (ci.intern "emit")))]
    [macro-call : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Call
          macro-func
          (ast.ast-expr-cons text-expr (ast.ast-expr-list-new))))]
    [links : ast.AstExternLinkInputList
      (let
        [items : ast.AstExternLinkInputList
          (ast.ast-extern-link-input-list-new)]
        (begin
          (ast.ast-extern-link-input-list-push
            (&mut items)
            (ast.AstExternLinkInput.Lib "m"))
          items))]
    [variants : ast.AstDispatchVariantList
      (let
        [items : ast.AstDispatchVariantList (ast.ast-dispatch-variant-list-new)]
        (begin
          (ast.ast-dispatch-variant-list-push
            (&mut items)
            (ast.AstDispatchVariant.Variant (ast.AstDispatchIsa.Avx2) "fast"))
          items))]
    [lifetimes : ast.AstLifetimeList
      (let
        [items : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
        (begin
          (ast.ast-lifetime-list-push (&mut items) "owner")
          items))]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-def
            "text"
            (ast.AstMaybeType.Some (ast.AstType.Ref "borrowed" source-i64-ty))
            text-expr)
          (ast.ast-decl-cons
            (ast.ast-decl-def "bin" ast.AstMaybeType.No binary-expr)
            (ast.ast-decl-cons
              (ast.AstDecl.Import
                (ast.AstImportSpec.Spec
                  (ast.AstImportKind.Path)
                  "pkg/path"
                  (ast.AstMaybeModuleName.Some "pkg.module")
                  (ast.AstMaybeImportAlias.Some "pkg")
                  (box (ast.ast-source-span 1 1 1 1))))
              (ast.ast-decl-cons
                (ast.ast-decl-extern
                  "native"
                  (ast.AstExternKind.Function)
                  (ast.AstExternMetadata.Metadata
                    (ast.AstExternAbi.C)
                    "native_symbol"
                    links
                    true)
                  (ast.AstType.I64))
                (ast.ast-decl-cons
                  (ast.AstDecl.Import
                    (ast.AstImportSpec.Spec
                      (ast.AstImportKind.Macro
                        macro-call
                        ast.AstMaybeModuleName.No)
                      ""
                      ast.AstMaybeModuleName.No
                      ast.AstMaybeImportAlias.No
                      (box (ast.ast-source-span 2 1 2 1))))
                  (ast.ast-decl-cons
                    (ast.AstDecl.Import
                      (ast.AstImportSpec.Spec
                        (ast.AstImportKind.MacroDecls
                          macro-call
                          ast.AstMaybeModuleName.No)
                        ""
                        ast.AstMaybeModuleName.No
                        ast.AstMaybeImportAlias.No
                        (box (ast.ast-source-span 3 1 3 1))))
                    (ast.ast-decl-cons
                      (ast.ast-decl-def-dispatch "dispatch" variants)
                      (ast.ast-decl-cons
                        (ast.AstDecl.DefStructLifetimes
                          0
                          lifetimes
                          (ast.AstStructRepr.Default)
                          (ast.AstStructCleanup.No)
                          (ast.ast-field-def-list-new))
                        (ast.ast-decl-cons
                          (ast.AstDecl.IncludeStr "inc" "data.txt")
                          (ast.ast-decl-list-new)))))))))))]
    [compacted : ast.AstProgramCompaction
      (ast.ast-program-compact-with-pools source-pools dest-pools program)]
    (match compacted
      [(ast.AstProgramCompaction out-program out-pools)
        (match out-program
          [(ast.AstProgram.Program decls-box)
            (let
              [decls : ast.AstDeclList (box-get decls-box)]
              (and
                (compiler-ast-compaction-string-def-ok?
                  out-pools
                  (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-binary-def-ok?
                  out-pools
                  (ast.ast-decl-list-get (& decls) 1 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-import-ok?
                  (ast.ast-decl-list-get (& decls) 2 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-extern-ok?
                  (ast.ast-decl-list-get (& decls) 3 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-macro-import-ok?
                  out-pools
                  (ast.ast-decl-list-get (& decls) 4 (ast.ast-decl-fallback))
                  false)
                (compiler-ast-compaction-macro-import-ok?
                  out-pools
                  (ast.ast-decl-list-get (& decls) 5 (ast.ast-decl-fallback))
                  true)
                (compiler-ast-compaction-dispatch-ok?
                  (ast.ast-decl-list-get (& decls) 6 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-lifetimes-ok?
                  (ast.ast-decl-list-get (& decls) 7 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-include-ok?
                  (ast.ast-decl-list-get (& decls) 8 (ast.ast-decl-fallback)))))])])))

(define (compiler-ast-decl-list-module-name?
  [decls : ast.AstDeclList]
  [index : i64]
  [expected : String]) : bool
  (match (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))
    [(ast.AstDecl.Module name) (string.eq (ci.intern-str name) expected)]
    [_ false]))

(define (compiler-ast-decl-cons-growth-smoke?) : bool
  (let
    [i : i64 15]
    [decls : ast.AstDeclList (ast.ast-decl-list-new)]
    [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
    [modules : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
    (begin
      (while (>= i 0)
        (let
          [suffix : String (string.int->string i)]
          [module : String (string.append "m" suffix)]
          [path : String (string.append "p" suffix)]
          (begin
            (set! decls (ast.ast-decl-cons (ast.ast-decl-module module) decls))
            (set! paths (ast.ast-decl-path-cons path paths))
            (set! modules (ast.ast-decl-module-cons module modules))
            (set! i (- i 1)))))
      (let
        [tail : ast.AstDeclList (ast.ast-decl-list-tail decls)]
        (and
          (= (ast.ast-decl-list-len (& decls)) 16)
          (= (ast.ast-decl-path-list-len (& paths)) 16)
          (= (ast.ast-decl-module-list-len (& modules)) 16)
          (compiler-ast-decl-list-module-name? decls 0 "m0")
          (compiler-ast-decl-list-module-name? decls 7 "m7")
          (compiler-ast-decl-list-module-name? decls 15 "m15")
          (compiler-ast-decl-list-module-name? tail 0 "m1")
          (string.eq (ast.ast-decl-path-list-get (& paths) 0 "") "p0")
          (string.eq (ast.ast-decl-path-list-get (& paths) 15 "") "p15")
          (string.eq (ast.ast-decl-module-list-get (& modules) 0 "") "m0")
          (string.eq (ast.ast-decl-module-list-get (& modules) 15 "") "m15"))))))

(define (compiler-ast-decl-cons-pure-smoke?) : bool
  (let
    [tail : ast.AstDeclList
      (ast.ast-decl-cons (ast.ast-decl-module "tail") (ast.ast-decl-list-new))]
    [left : ast.AstDeclList
      (ast.ast-decl-cons (ast.ast-decl-module "left") tail)]
    [right : ast.AstDeclList
      (ast.ast-decl-cons (ast.ast-decl-module "right") tail)]
    (and
      (compiler-ast-decl-list-module-name? left 0 "left")
      (compiler-ast-decl-list-module-name? left 1 "tail")
      (compiler-ast-decl-list-module-name? right 0 "right")
      (compiler-ast-decl-list-module-name? right 1 "tail"))))

(define (compiler-ast-clause-list-tail-smoke?) : bool
  (let
    [clauses : ast.AstExprClauseList (ast.ast-expr-clause-list-new)]
    [bindings : ast.AstExprBindingClauseList
      (ast.ast-expr-binding-clause-list-new)]
    (begin
      (ast.ast-expr-clause-list-push (&mut clauses) (ast.ast-expr-clause 1 2))
      (ast.ast-expr-clause-list-push (&mut clauses) (ast.ast-expr-clause 3 4))
      (ast.ast-expr-clause-list-push (&mut clauses) (ast.ast-expr-clause 5 6))
      (ast.ast-expr-binding-clause-list-push
        (&mut bindings)
        (ast.ast-expr-binding-clause-id
          10
          false
          0
          100
          (ast.ast-source-span 1 1 1 2)))
      (ast.ast-expr-binding-clause-list-push
        (&mut bindings)
        (ast.ast-expr-binding-clause-id
          11
          false
          0
          101
          (ast.ast-source-span 2 1 2 2)))
      (ast.ast-expr-binding-clause-list-push
        (&mut bindings)
        (ast.ast-expr-binding-clause-id
          12
          false
          0
          102
          (ast.ast-source-span 3 1 3 2)))
      (let
        [clause-tail : ast.AstExprClauseList
          (ast.ast-expr-clause-list-tail clauses)]
        [binding-tail : ast.AstExprBindingClauseList
          (ast.ast-expr-binding-clause-list-tail bindings)]
        [first-clause : ast.AstExprClause
          (ast.ast-expr-clause-list-get
            (& clause-tail)
            0
            (ast.ast-expr-clause-fallback))]
        [first-binding : ast.AstExprBindingClause
          (ast.ast-expr-binding-clause-list-get
            (& binding-tail)
            0
            (ast.ast-expr-binding-clause-fallback))]
        (and
          (= (struct-get (& clause-tail) len) 2)
          (= (struct-get first-clause first) 3)
          (= (struct-get first-clause second) 4)
          (= (struct-get (& binding-tail) len) 2)
          (= (struct-get first-binding name) 11)
          (= (struct-get first-binding init) 101))))))

;; Rewriters select an owned AST-pool context while the process-global active
;; pool may hold an unrelated compilation. `ast-node-set!` must update that
;; selected context just like `ast-node-get` and `ast-node-push` do.
(define (compiler-ast-compat-context-set-smoke?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    (begin
      (ast.ast-node-pool-compat-context-use! pools)
      (let
        [id : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 7)))]
        (begin
          (ast.ast-node-set! id (ast.AstExpr.Literal (ast.ast-lit-int 42)))
          (ast.ast-node-pool-compat-context-clear!)
          (and (= id 0) (compiler-ast-context-expr-int-lit? pools id 42)))))))

(define (compiler-ast-name-provenance-smoke?) : bool
  (begin
    (ci.intern-reset!)
    (let
      ;; This is the historical parser-only assertion in executable form: a
      ;; compatibility constructor must accept synthesis whose spelling was not
      ;; already present as a parser token.
      [empty-was-not-parsed : bool
        (match (ci.intern-lookup "")
          [(ci.InternLookupMissing) true]
          [(ci.InternLookupFound _) false])]
      [empty-decl : ast.AstDecl (ast.ast-decl-def "" (ast.AstMaybeType.No) 0)]
      [generated-id : i64 (ci.intern "generated.module/helper")]
      [generated-decl : ast.AstDecl
        (ast.ast-decl-module-body-id generated-id (ast.ast-decl-list-new))]
      [hygiene-id : i64 (ci.intern "__macro_hygiene_42")]
      [hygiene-expr : ast.AstExpr (ast.AstExpr.Var hygiene-id)]
      [builtin-decl : ast.AstDecl
        (ast.ast-decl-extern
          "tl_alloc"
          (ast.AstExternKind.Function)
          (ast.AstExternMetadata.Metadata
            (ast.AstExternAbi.C)
            "tl_alloc"
            (ast.ast-extern-link-input-list-new)
            false)
          (ast.AstType.I64))]
      [fallback-param : ast.AstParam (ast.ast-param-fallback)]
      [sentinel-type : ast.AstType (ast.AstType.Struct -1)]
      [structural-type : ast.AstType
        (ast.AstType.Enum (+ (ci.intern-capacity) 7))]
      (and
        empty-was-not-parsed
        (match empty-decl
          [(ast.AstDecl.Def name _ _) (string.eq (ci.intern-str name) "")]
          [_ false])
        (match generated-decl
          [(ast.AstDecl.ModuleBody name _)
            (and
              (= name generated-id)
              (string.eq (ci.intern-str name) "generated.module/helper"))]
          [_ false])
        (match hygiene-expr
          [(ast.AstExpr.Var name)
            (and
              (= name hygiene-id)
              (string.eq (ci.intern-str name) "__macro_hygiene_42"))]
          [_ false])
        (match builtin-decl
          [(ast.AstDecl.Extern name _ _ _)
            (string.eq (ci.intern-str name) "tl_alloc")]
          [_ false])
        ;; Fallback payload ids are shape sentinels and are never rendered.
        (match fallback-param
          [(ast.AstParam.Param name _ _ _) (= name 0)])
        (match sentinel-type
          [(ast.AstType.Struct name)
            (string.eq
              (ast.ast-nominal-name-display name)
              "<structural-nominal>")]
          [_ false])
        (match structural-type
          [(ast.AstType.Enum name)
            (string.eq
              (ast.ast-nominal-name-display name)
              "<structural-nominal>")]
          [_ false])))))

(define (main) : i64
  (begin
    (unless (= (ast.compiler-ast-smoke) 23) (return 2))
    (unless (compiler-ast-state-owned-node-pools-smoke?) (return 3))
    (unless (compiler-ast-active-context-sync-smoke?) (return 4))
    (unless (compiler-ast-program-compaction-smoke?) (return 5))
    (unless (compiler-ast-program-copy-append-smoke?) (return 13))
    (unless (compiler-ast-decl-cons-growth-smoke?) (return 6))
    (unless (compiler-ast-decl-cons-pure-smoke?) (return 7))
    (unless (compiler-ast-program-compaction-string-payloads-smoke?) (return 8))
    (unless (compiler-ast-compat-context-set-smoke?) (return 9))
    (unless (compiler-ast-context-clone-types-only-smoke?) (return 10))
    (unless (compiler-ast-clause-list-tail-smoke?) (return 11))
    (unless (compiler-ast-name-provenance-smoke?) (return 12))
    42))