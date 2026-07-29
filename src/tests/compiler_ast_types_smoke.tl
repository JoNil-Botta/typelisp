;; compiler_ast_types_smoke.tl - Runnable AST data-shape smoke.
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import stdlib.arena)
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

(define (compiler-ast-state-owned-type-dedup-budget-smoke?) : bool
  ;; Keep the source-macro self-host uniqueness budget from silently shrinking
  ;; back below the measured 37.5K-node surface.
  (>=
    (array-length
      (struct-get (ast.ast-type-node-pool-state-create 1) dedup-slots))
    131072))

(define (compiler-ast-state-owned-node-pools-smoke?) : bool
  (and
    (compiler-ast-state-owned-expr-pool-smoke?)
    (compiler-ast-state-owned-type-pool-smoke?)
    (compiler-ast-state-owned-type-dedup-reuse-smoke?)
    (compiler-ast-state-owned-type-dedup-isolated-smoke?)
    (compiler-ast-state-owned-type-dedup-reset-smoke?)
    (compiler-ast-state-owned-type-dedup-budget-smoke?)))

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
            [(ast.AstDecl.Def _ _ maybe-ty first-body)
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
                              [(ast.AstDecl.Def _ _ _ make-body)
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
        (ast.ast-type-node-pool-state-create 8)
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8)
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
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
        (ast.AstExpr.MakeArray
          (ast.ast-node-pool-context-type-push
            source-pools
            (ast.AstType.Ptr source-i64-ty))
          source-body))]
    [value-name-id : i64 (ci.intern-generated-name "value")]
    [same-name-id : i64 (ci.intern-generated-name "same")]
    [array-name-id : i64 (ci.intern-generated-name "array")]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-def-id
            value-name-id
            (ast.AstMaybeType.Some array-ty)
            source-body)
          (ast.ast-decl-cons
            (ast.ast-decl-test-id
              same-name-id
              source-body
              (ast.ast-source-span 5 6 7 8))
            (ast.ast-decl-cons
              (ast.ast-decl-def-id
                array-name-id
                ast.AstMaybeType.No
                source-make)
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
                      [(ast.AstDecl.Def _ _ maybe-ty body)
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
    [appended-name-id : i64 (ci.intern-generated-name "appended")]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-def-id
            appended-name-id
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
                    [(ast.AstDecl.Def _ _ maybe-type body)
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

(define (compiler-ast-compaction-borrow-child-smoke?) : bool
  (let
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 1)]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 1)]
    [name : i64 (ci.intern-generated-name "borrow-child")]
    [var-id : i64
      (ast.ast-node-pool-context-expr-push source-pools (ast.AstExpr.Var name))]
    [spanned-id : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Spanned var-id (ast.ast-source-span 1 1 1 2)))]
    [borrow-id : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Borrow
          false
          (ast.ast-borrow-lifetime-to-id ast.AstBorrowLifetime.Inferred)
          spanned-id))]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-def-id name ast.AstMaybeType.No borrow-id)
          (ast.ast-decl-list-new)))]
    [compacted : ast.AstProgramCompaction
      (ast.ast-program-compact-with-pools source-pools dest-pools program)]
    (match compacted
      [(ast.AstProgramCompaction out-program out-pools)
        (match out-program
          [(ast.AstProgram.Program decls-box)
            (match (ast.ast-decl-list-step (box-get decls-box))
              [(ast.AstDeclListStep.Cons decl _)
                (match decl
                  [(ast.AstDecl.Def _ _ _ body)
                    (match (ast.ast-node-pool-context-expr-get out-pools body)
                      [(ast.AstExpr.Borrow mutable lifetime-id inner)
                        (and
                          (not mutable)
                          (match (ast.ast-borrow-lifetime-from-id lifetime-id)
                            [(ast.AstBorrowLifetime.Inferred) true]
                            [_ false])
                          (match (ast.ast-node-pool-context-expr-get
                            out-pools
                            inner)
                            [(ast.AstExpr.Spanned var _)
                              (match (ast.ast-node-pool-context-expr-get
                                out-pools
                                var)
                                [(ast.AstExpr.Var got-name) (= got-name name)]
                                [_ false])]
                            [_ false]))]
                      [_ false])]
                  [_ false])]
              [_ false])])])))

(define (compiler-ast-compaction-string-def-ok?
  [pools : ast.AstNodePoolContext]
  [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Def _ _ maybe-ty value)
      (and
        (match maybe-ty
          [(ast.AstMaybeType.Some ty)
            (match ty
              [(ast.AstType.Ref region inner)
                (and
                  (= region cbi.compiler-builtin-id-fix-value)
                  (match (ast.ast-node-pool-context-type-get pools inner)
                    [(ast.AstType.I64) true]
                    [_ false]))]
              [_ false])]
          [_ false])
        (match (ast.ast-node-pool-context-expr-get pools value)
          [(ast.AstExpr.Literal (ast.AstLiteral.String string-id))
            (string.eq (ast.ast-lit-string-text string-id) "hello")]
          [_ false]))]
    [_ false]))

(define (compiler-ast-compaction-binary-def-ok?
  [pools : ast.AstNodePoolContext]
  [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Def _ _ ast.AstMaybeType.No value)
      (match (ast.ast-node-pool-context-expr-get pools value)
        [(ast.AstExpr.BinaryData text) (string.eq text "bytes")]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-import-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Import
        _
        (ast.AstImportSpec.Spec
          (ast.AstImportKind.Path)
          path
          module-name
          alias
          _))
      (and
        (string.eq path "pkg/path")
        (match module-name
          [(ast.AstMaybeModuleName.Some name)
            (string.eq (ci.intern-str name) "pkg.module")]
          [_ false])
        (match alias
          [(ast.AstMaybeImportAlias.Some name)
            (string.eq (ci.intern-str name) "pkg")]
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
    [(ast.AstDecl.Import _ (ast.AstImportSpec.Spec kind _ _ _ _))
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
    [(ast.AstDecl.Extern _ _ _ metadata _)
      (match (box-get metadata)
        [(ast.AstExternMetadata.Metadata
            (ast.AstExternAbi.C)
            symbol
            links
            flags
            _)
          (and
            (ast.ast-extern-metadata-flags-explicit-abi? flags)
            (not (ast.ast-extern-metadata-flags-symbol-matches-source? flags))
            (string.eq (ci.intern-str symbol) "native_symbol")
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
    [(ast.AstDecl.DefDispatch _ _ variants)
      (match (ast.ast-dispatch-variant-list-get
        (& variants)
        0
        (ast.ast-dispatch-variant-fallback))
        [(ast.AstDispatchVariant.Variant (ast.AstDispatchIsa.Avx2) name)
          (string.eq (ci.intern-str name) "fast")]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-lifetimes-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.DefStructLifetimes _ _ lifetimes _ _ _)
      (=
        (ast.ast-lifetime-list-get (& lifetimes) 0 (ast.ast-lifetime-fallback))
        cbi.compiler-builtin-id-fix-n)]
    [_ false]))

(define (compiler-ast-compaction-include-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.IncludeStr name path)
      (and (string.eq (ci.intern-str name) "inc") (string.eq path "data.txt"))]
    [_ false]))

(define (compiler-ast-program-compaction-string-payloads-smoke?) : bool
  (let
    [include-name-id : i64 (ci.intern-generated-name "inc")]
    [macro-func-name-id : i64 (ci.intern-generated-name "emit")]
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8)
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8)
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [source-i64-ty : i64
      (ast.ast-node-pool-context-type-push source-pools (ast.AstType.I64))]
    [_source-decoy : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Literal (ast.ast-lit-int 999)))]
    [text-expr : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Literal (ast.ast-lit-generated-string "hello")))]
    [binary-expr : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.BinaryData "bytes"))]
    [macro-func : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Var macro-func-name-id))]
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
            (ast.AstDispatchVariant.Variant
              (ast.AstDispatchIsa.Avx2)
              (ci.intern-generated-name "fast")))
          items))]
    [lifetimes : ast.AstLifetimeList
      (let
        [items : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
        (begin
          (ast.ast-lifetime-list-push
            (&mut items)
            cbi.compiler-builtin-id-fix-n)
          items))]
    [text-name-id : i64 (ci.intern-generated-name "text")]
    [bin-name-id : i64 (ci.intern-generated-name "bin")]
    [native-name-id : i64 (ci.intern-generated-name "native")]
    [dispatch-name-id : i64 (ci.intern-generated-name "dispatch")]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-def-id
            text-name-id
            (ast.AstMaybeType.Some
              (ast.AstType.Ref cbi.compiler-builtin-id-fix-value source-i64-ty))
            text-expr)
          (ast.ast-decl-cons
            (ast.ast-decl-def-id bin-name-id ast.AstMaybeType.No binary-expr)
            (ast.ast-decl-cons
              (ast.AstDecl.Import
                ast.ast-decl-meta-runtime
                (ast.AstImportSpec.Spec
                  (ast.AstImportKind.Path)
                  "pkg/path"
                  (ast.AstMaybeModuleName.Some
                    (ci.intern-generated-name "pkg.module"))
                  (ast.AstMaybeImportAlias.Some
                    (ci.intern-generated-name "pkg"))
                  (box (ast.ast-source-span 1 1 1 1))))
              (ast.ast-decl-cons
                (ast.ast-decl-extern-id
                  native-name-id
                  (ast.AstExternKind.Function)
                  (ast.AstExternMetadata.Metadata
                    (ast.AstExternAbi.C)
                    (ci.intern-generated-name "native_symbol")
                    links
                    (ast.ast-extern-metadata-flags true false)
                    ast.AstImportedSpmdMetadata.No)
                  (ast.AstType.I64))
                (ast.ast-decl-cons
                  (ast.AstDecl.Import
                    ast.ast-decl-meta-runtime
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
                      ast.ast-decl-meta-runtime
                      (ast.AstImportSpec.Spec
                        (ast.AstImportKind.MacroDecls
                          macro-call
                          ast.AstMaybeModuleName.No)
                        ""
                        ast.AstMaybeModuleName.No
                        ast.AstMaybeImportAlias.No
                        (box (ast.ast-source-span 3 1 3 1))))
                    (ast.ast-decl-cons
                      (ast.ast-decl-def-dispatch-id dispatch-name-id variants)
                      (ast.ast-decl-cons
                        (ast.AstDecl.DefStructLifetimes
                          ast.ast-decl-meta-runtime
                          0
                          lifetimes
                          (ast.AstStructRepr.Default)
                          (ast.AstStructCleanup.No)
                          (ast.ast-field-def-list-new))
                        (ast.ast-decl-cons
                          (ast.AstDecl.IncludeStr include-name-id "data.txt")
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
          [module-id : i64 (ci.intern-generated-name module)]
          [path : String (string.append "p" suffix)]
          (begin
            (set!
              decls
              (ast.ast-decl-cons (ast.ast-decl-module-id module-id) decls))
            (set! paths (ast.ast-decl-root-path-cons path paths))
            (set!
              modules
              (ast.ast-decl-module-list-prepend-builder-id module-id modules))
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
    [tail-id : i64 (ci.intern-generated-name "tail")]
    [left-id : i64 (ci.intern-generated-name "left")]
    [right-id : i64 (ci.intern-generated-name "right")]
    [tail : ast.AstDeclList
      (ast.ast-decl-cons
        (ast.ast-decl-module-id tail-id)
        (ast.ast-decl-list-new))]
    [left : ast.AstDeclList
      (ast.ast-decl-cons (ast.ast-decl-module-id left-id) tail)]
    [right : ast.AstDeclList
      (ast.ast-decl-cons (ast.ast-decl-module-id right-id) tail)]
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
          (ast.AstType.Var -3)
          (ast.ast-source-span 1 1 1 2)))
      (ast.ast-expr-binding-clause-list-push
        (&mut bindings)
        (ast.ast-expr-binding-clause-id
          11
          false
          0
          101
          (ast.AstType.Var -3)
          (ast.ast-source-span 2 1 2 2)))
      (ast.ast-expr-binding-clause-list-push
        (&mut bindings)
        (ast.ast-expr-binding-clause-id
          12
          false
          0
          102
          (ast.AstType.Var -3)
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

(define (compiler-ast-generated-path-owner-smoke?) : bool
  (let
    [path : String "<generated ast smoke path>"]
    [path-id : i64 (ci.intern-generated-canonical-name path)]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-path-list-prepend-builder-with-owner-id
        path
        path-id
        (ast.ast-decl-path-list-new))]
    [with-modules : ast.AstDeclPathList
      (ast.ast-decl-path-list-with-modules paths (ast.ast-decl-module-list-new))]
    (= (ast.ast-decl-path-list-owner-id (& with-modules) 0 -1) path-id)))

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

;; Creating a retained pool while a source arena is active must not allocate the
;; context's mutable cells in that source arena. The compiler destroys the
;; source immediately after AST compaction, then continues using this context.
(define (compiler-ast-context-owned-arena-smoke?) : bool
  (let
    [home : arena.Arena (arena.current)]
    [source : arena.Arena (arena.make)]
    [dest : arena.Arena (arena.make)]
    [_set-source : unit
      (unsafe
        (arena.set! source))]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        4
        4
        (arena.raw-handle dest))]
    [_set-dest : unit
      (unsafe
        (arena.set! dest))]
    [child : i64
      (ast.ast-node-pool-context-expr-push
        pools
        (ast.AstExpr.Literal (ast.ast-lit-int 73)))]
    [body : ast.AstExprList (ast.ast-expr-list-new)]
    [_push-child : unit (ast.ast-expr-list-push (&mut body) child)]
    [unsafe-id : i64
      (ast.ast-node-pool-context-expr-push pools (ast.AstExpr.Unsafe body))]
    [_restore-home : unit
      (unsafe
        (arena.set! home))]
    [_destroy-source : unit
      (unsafe
        (arena.destroy source))]
    [ok : bool
      (match (ast.ast-node-pool-context-expr-get pools unsafe-id)
        [(ast.AstExpr.Unsafe exprs)
          (let
            [retained-child : i64 (ast.ast-expr-list-get (& exprs) 0 -1)]
            (and
              (= retained-child child)
              (compiler-ast-context-expr-int-lit? pools retained-child 73)))]
        [_ false])]
    (begin
      (ast.ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (arena.destroy dest))
      ok)))

;; Force several fixed-size expression and type segments in two independently
;; owned contexts. Boundary ids must continue to address their original nodes,
;; hash-consing must survive type-segment growth, and neither context may alias
;; the other's backing storage.
(define (compiler-ast-segmented-growth-isolation-smoke?) : bool
  (let
    [home : arena.Arena (arena.current)]
    [a-arena : arena.Arena (arena.make)]
    [b-arena : arena.Arena (arena.make)]
    [a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        1
        1
        (arena.raw-handle a-arena))]
    [b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        1
        1
        (arena.raw-handle b-arena))]
    [expr-index : i64 0]
    [type-index : i64 0]
    [a-last-expr : i64 -1]
    [b-last-expr : i64 -1]
    [a-last-type : i64 -1]
    [b-last-type : i64 -1]
    (begin
      (while (<= expr-index 131072)
        (begin
          (set!
            a-last-expr
            (ast.ast-node-pool-context-expr-push
              a
              (ast.AstExpr.Literal (ast.ast-lit-int expr-index))))
          (if (<= expr-index 65536)
            (set!
              b-last-expr
              (ast.ast-node-pool-context-expr-push
                b
                (ast.AstExpr.Literal (ast.ast-lit-int (- 0 expr-index)))))
            unit)
          (set! expr-index (+ expr-index 1))))
      (while (<= type-index 2048)
        (begin
          (set!
            a-last-type
            (ast.ast-node-pool-context-type-push a (ast.AstType.Var type-index)))
          (if (<= type-index 1024)
            (set!
              b-last-type
              (ast.ast-node-pool-context-type-push
                b
                (ast.AstType.Var (+ type-index 10000))))
            unit)
          (set! type-index (+ type-index 1))))
      (let
        [a-dupe-type : i64
          (ast.ast-node-pool-context-type-push a (ast.AstType.Var 1024))]
        [a-base : i64 (ast.ast-node-pool-context-base-arena a)]
        [b-base : i64 (ast.ast-node-pool-context-base-arena b)]
        [ok : bool
          (and
            (= a-last-expr 131072)
            (= b-last-expr 65536)
            (= a-last-type 2048)
            (= b-last-type 1024)
            (= a-dupe-type 1024)
            (= (ast.ast-node-pool-context-expr-segment-count a) 3)
            (= (ast.ast-node-pool-context-expr-segment-count b) 2)
            (= (ast.ast-node-pool-context-type-segment-count a) 3)
            (= (ast.ast-node-pool-context-type-segment-count b) 2)
            (compiler-ast-context-expr-int-lit? a 0 0)
            (compiler-ast-context-expr-int-lit? a 65535 65535)
            (compiler-ast-context-expr-int-lit? a 65536 65536)
            (compiler-ast-context-expr-int-lit? a 131072 131072)
            (compiler-ast-context-expr-int-lit? b 65536 -65536)
            (match (ast.ast-node-pool-context-type-get a 1024)
              [(ast.AstType.Var name) (= name 1024)]
              [_ false])
            (match (ast.ast-node-pool-context-type-get a 2048)
              [(ast.AstType.Var name) (= name 2048)]
              [_ false])
            (match (ast.ast-node-pool-context-type-get b 1024)
              [(ast.AstType.Var name) (= name 11024)]
              [_ false])
            (not (= a-base b-base))
            (not
              (=
                (ast.ast-node-pool-context-expr-storage-arena a)
                (ast.ast-node-pool-context-expr-storage-arena b))))]
        (begin
          (unsafe
            (arena.set! home))
          (ast.ast-node-pool-context-destroy-storage! a)
          (ast.ast-node-pool-context-destroy-storage! b)
          (unsafe
            (begin
              (arena.tl_arena_destroy a-base)
              (arena.tl_arena_destroy b-base)))
          ok)))))

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
    (unless (compiler-ast-generated-path-owner-smoke?) (return 12))
    (unless (compiler-ast-context-owned-arena-smoke?) (return 13))
    (unless (compiler-ast-compaction-borrow-child-smoke?) (return 14))
    (unless (compiler-ast-segmented-growth-isolation-smoke?) (return 15))
    42))