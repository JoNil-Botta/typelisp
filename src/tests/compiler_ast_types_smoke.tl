;; compiler_ast_types_smoke.tl - Runnable AST data-shape smoke.
(import "../compiler_ast_types.tl")
(import stdlib.string)

(define (compiler-ast-state-expr-int-lit?
  [pool : AstExprNodePoolState]
  [id : i64]
  [expected : i64]) : bool
  (match (ast-expr-node-pool-state-get pool id)
    [(AstExpr.Literal lit)
      (match lit
        [(AstLiteral.Int value _) (= value expected)]
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

(define (compiler-ast-context-type-i64? [pools : AstNodePoolContext] [id : i64]) : bool
  (match (ast-node-pool-context-type-get pools id)
    [(AstType.I64) true]
    [_ false]))

(define (compiler-ast-context-type-char?
  [pools : AstNodePoolContext]
  [id : i64]) : bool
  (match (ast-node-pool-context-type-get pools id)
    [(AstType.Char) true]
    [_ false]))

(define (compiler-ast-context-expr-int-lit?
  [pools : AstNodePoolContext]
  [id : i64]
  [expected : i64]) : bool
  (match (ast-node-pool-context-expr-get pools id)
    [(AstExpr.Literal lit)
      (match lit
        [(AstLiteral.Int value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-ast-context-base-arenas-match? [pools : AstNodePoolContext]) : bool
  (let
    [expr-pool : AstExprNodePoolState
      (array-ref (struct-get pools expr-pool) 0)]
    [type-pool : AstTypeNodePoolState
      (array-ref (struct-get pools type-pool) 0)]
    (= (struct-get expr-pool base-arena) (struct-get type-pool base-arena))))

(define (compiler-ast-active-context-sync-smoke?) : bool
  (let
    [active-before : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [pools : AstNodePoolContext (ast-node-pool-context-new-with-capacities 1 1)]
    [ok : bool true]
    (begin
      (ast-node-pool-context-install! pools)
      (let
        [expr-a : i64 (ast-node-push (AstExpr.Literal (ast-lit-int 31)))]
        [expr-b : i64 (ast-node-push (AstExpr.Literal (ast-lit-int 32)))]
        [type-a : i64 (ty-node-push (AstType.I64))]
        [type-b : i64 (ty-node-push (AstType.Char))]
        (begin
          (unless (= expr-a 0) (set! ok false))
          (unless (= expr-b 1) (set! ok false))
          (unless (= type-a 0) (set! ok false))
          (unless (= type-b 1) (set! ok false))
          (unless (= (ast-node-pool-context-expr-len pools) 2) (set! ok false))
          (unless (= (ast-node-pool-context-type-len pools) 2) (set! ok false))
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
          (ast-node-pool-truncate! 1)
          (ty-node-pool-truncate! 1)
          (unless (= (ast-node-pool-context-expr-len pools) 1) (set! ok false))
          (unless (= (ast-node-pool-context-type-len pools) 1) (set! ok false))
          (unless
            (compiler-ast-context-expr-int-lit? pools expr-a 31)
            (set! ok false))
          (unless (compiler-ast-context-type-i64? pools type-a) (set! ok false))
          (ast-node-pool-context-install! active-before)
          ok)))))

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
              (= (ast-source-span-start-line span) 1)
              (= (ast-source-span-start-col span) 2)
              (= (ast-source-span-end-line span) 3)
              (= (ast-source-span-end-col span) 4)
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
                    [(AstLiteral.Int value _) (= value 7)]
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
  [source-span : i64]
  [source-make : i64]) : bool
  (match program
    [(AstProgram.Program decls-box)
      (match (ast-decl-list-step (box-get decls-box))
        [(AstDeclListStep.Cons first rest-box)
          (match first
            [(AstDecl.Def _ maybe-ty first-body)
              (match (ast-decl-list-step rest-box)
                [(AstDeclListStep.Cons second tail-box)
                  (match second
                    [(AstDecl.Test _ second-body _)
                      (and
                        (= first-body second-body)
                        (not (= first-body source-body))
                        (= (ast-node-pool-context-expr-len pools) 4)
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
                        (match (ast-decl-list-step tail-box)
                          [(AstDeclListStep.Cons third final-box)
                            (match third
                              [(AstDecl.Def _ _ make-body)
                                (and
                                  (not (= make-body source-make))
                                  (match (ast-node-pool-context-expr-get
                                    pools
                                    make-body)
                                    [(AstExpr.MakeArray _ size-body)
                                      (= size-body first-body)]
                                    [_ false])
                                  (match (ast-decl-list-step final-box)
                                    [(AstDeclListStep.Nil) true]
                                    [_ false]))]
                              [_ false])]
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
        (AstExpr.Spanned source-lit (ast-source-span 1 2 3 4)))]
    [source-body : i64
      (ast-node-pool-context-expr-push
        source-pools
        (AstExpr.Binary (AstBinOp.Add) source-span source-span))]
    [source-make : i64
      (ast-node-pool-context-expr-push
        source-pools
        (AstExpr.MakeArray (AstType.Ptr source-i64-ty) source-body))]
    [program : AstProgram
      (ast-program
        (ast-decl-cons
          (ast-decl-def "value" (AstMaybeType.Some array-ty) source-body)
          (ast-decl-cons
            (ast-decl-test "same" source-body (ast-source-span 5 6 7 8))
            (ast-decl-cons
              (ast-decl-def "array" AstMaybeType.No source-make)
              (ast-decl-list-new)))))]
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
                source-span
                source-make))]
          [installed-ok : bool
            (match out-program
              [(AstProgram.Program decls-box)
                (match (ast-decl-list-step (box-get decls-box))
                  [(AstDeclListStep.Cons first _)
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

(define (compiler-ast-compaction-string-def-ok?
  [pools : AstNodePoolContext]
  [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Def _ maybe-ty value)
      (and
        (match maybe-ty
          [(AstMaybeType.Some ty)
            (match ty
              [(AstType.Ref region inner)
                (and
                  (string.eq region "borrowed")
                  (match (ast-node-pool-context-type-get pools inner)
                    [(AstType.I64) true]
                    [_ false]))]
              [_ false])]
          [_ false])
        (match (ast-node-pool-context-expr-get pools value)
          [(AstExpr.Literal (AstLiteral.String text)) (string.eq text "hello")]
          [_ false]))]
    [_ false]))

(define (compiler-ast-compaction-binary-def-ok?
  [pools : AstNodePoolContext]
  [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Def _ AstMaybeType.No value)
      (match (ast-node-pool-context-expr-get pools value)
        [(AstExpr.BinaryData text) (string.eq text "bytes")]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-import-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Import
        (AstImportSpec.Spec (AstImportKind.Path) path module-name alias _))
      (and
        (string.eq path "pkg/path")
        (match module-name
          [(AstMaybeModuleName.Some name) (string.eq name "pkg.module")]
          [_ false])
        (match alias
          [(AstMaybeImportAlias.Some name) (string.eq name "pkg")]
          [_ false]))]
    [_ false]))

(define (compiler-ast-compaction-extern-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Extern _ _ metadata _)
      (match metadata
        [(AstExternMetadata.Metadata (AstExternAbi.C) symbol links true)
          (and
            (string.eq symbol "native_symbol")
            (match (ast-extern-link-input-list-get
              (& links)
              0
              (ast-extern-link-input-fallback))
              [(AstExternLinkInput.Lib name) (string.eq name "m")]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-dispatch-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.DefDispatch _ variants)
      (match (ast-dispatch-variant-list-get
        (& variants)
        0
        (ast-dispatch-variant-fallback))
        [(AstDispatchVariant.Variant (AstDispatchIsa.Avx2) name)
          (string.eq name "fast")]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-lifetimes-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.DefStructLifetimes _ lifetimes _ _ _)
      (string.eq (ast-lifetime-list-get (& lifetimes) 0 "") "owner")]
    [_ false]))

(define (compiler-ast-compaction-include-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.IncludeStr name path)
      (and (string.eq name "inc") (string.eq path "data.txt"))]
    [_ false]))

(define (compiler-ast-program-compaction-string-payloads-smoke?) : bool
  (let
    [source-pools : AstNodePoolContext
      (ast-node-pool-context-new
        (ast-expr-node-pool-state-create 8)
        (ast-type-node-pool-state-create 8))]
    [dest-pools : AstNodePoolContext
      (ast-node-pool-context-new
        (ast-expr-node-pool-state-create 8)
        (ast-type-node-pool-state-create 8))]
    [source-i64-ty : i64
      (ast-node-pool-context-type-push source-pools (AstType.I64))]
    [text-expr : i64
      (ast-node-pool-context-expr-push
        source-pools
        (AstExpr.Literal (AstLiteral.String "hello")))]
    [binary-expr : i64
      (ast-node-pool-context-expr-push
        source-pools
        (AstExpr.BinaryData "bytes"))]
    [links : AstExternLinkInputList
      (begin
        (let
          [items : AstExternLinkInputList (ast-extern-link-input-list-new)]
          (begin
            (ast-extern-link-input-list-push
              (&mut items)
              (AstExternLinkInput.Lib "m"))
            items)))]
    [variants : AstDispatchVariantList
      (begin
        (let
          [items : AstDispatchVariantList (ast-dispatch-variant-list-new)]
          (begin
            (ast-dispatch-variant-list-push
              (&mut items)
              (AstDispatchVariant.Variant (AstDispatchIsa.Avx2) "fast"))
            items)))]
    [lifetimes : AstLifetimeList
      (begin
        (let
          [items : AstLifetimeList (ast-lifetime-list-new)]
          (begin
            (ast-lifetime-list-push (&mut items) "owner")
            items)))]
    [program : AstProgram
      (ast-program
        (ast-decl-cons
          (ast-decl-def
            "text"
            (AstMaybeType.Some (AstType.Ref "borrowed" source-i64-ty))
            text-expr)
          (ast-decl-cons
            (ast-decl-def "bin" AstMaybeType.No binary-expr)
            (ast-decl-cons
              (AstDecl.Import
                (AstImportSpec.Spec
                  (AstImportKind.Path)
                  "pkg/path"
                  (AstMaybeModuleName.Some "pkg.module")
                  (AstMaybeImportAlias.Some "pkg")
                  (ast-source-span 1 1 1 1)))
              (ast-decl-cons
                (ast-decl-extern
                  "native"
                  (AstExternKind.Function)
                  (AstExternMetadata.Metadata
                    (AstExternAbi.C)
                    "native_symbol"
                    links
                    true)
                  (AstType.I64))
                (ast-decl-cons
                  (ast-decl-def-dispatch "dispatch" variants)
                  (ast-decl-cons
                    (AstDecl.DefStructLifetimes
                      0
                      lifetimes
                      (AstStructRepr.Default)
                      (AstStructCleanup.No)
                      (ast-field-def-list-new))
                    (ast-decl-cons
                      (AstDecl.IncludeStr "inc" "data.txt")
                      (ast-decl-list-new)))))))))]
    [compacted : AstProgramCompaction
      (ast-program-compact-with-pools source-pools dest-pools program)]
    (match compacted
      [(AstProgramCompaction out-program out-pools)
        (match out-program
          [(AstProgram.Program decls-box)
            (let
              [decls : AstDeclList (box-get decls-box)]
              (and
                (compiler-ast-compaction-string-def-ok?
                  out-pools
                  (ast-decl-list-get (& decls) 0 (ast-decl-fallback)))
                (compiler-ast-compaction-binary-def-ok?
                  out-pools
                  (ast-decl-list-get (& decls) 1 (ast-decl-fallback)))
                (compiler-ast-compaction-import-ok?
                  (ast-decl-list-get (& decls) 2 (ast-decl-fallback)))
                (compiler-ast-compaction-extern-ok?
                  (ast-decl-list-get (& decls) 3 (ast-decl-fallback)))
                (compiler-ast-compaction-dispatch-ok?
                  (ast-decl-list-get (& decls) 4 (ast-decl-fallback)))
                (compiler-ast-compaction-lifetimes-ok?
                  (ast-decl-list-get (& decls) 5 (ast-decl-fallback)))
                (compiler-ast-compaction-include-ok?
                  (ast-decl-list-get (& decls) 6 (ast-decl-fallback)))))])])))

(define (compiler-ast-decl-list-module-name?
  [decls : AstDeclList]
  [index : i64]
  [expected : String]) : bool
  (match (ast-decl-list-get (& decls) index (ast-decl-fallback))
    [(AstDecl.Module name) (string.eq (intern-str name) expected)]
    [_ false]))

(define (compiler-ast-decl-cons-growth-smoke?) : bool
  (let
    [i : i64 15]
    [decls : AstDeclList (ast-decl-list-new)]
    [paths : AstDeclPathList (ast-decl-path-list-new)]
    [modules : AstDeclModuleList (ast-decl-module-list-new)]
    (begin
      (while (>= i 0)
        (let
          [suffix : String (string.int->string i)]
          [module : String (string.append "m" suffix)]
          [path : String (string.append "p" suffix)]
          (begin
            (set! decls (ast-decl-cons (ast-decl-module module) decls))
            (set! paths (ast-decl-path-cons path paths))
            (set! modules (ast-decl-module-cons module modules))
            (set! i (- i 1)))))
      (let
        [tail : AstDeclList (ast-decl-list-tail decls)]
        (and
          (= (ast-decl-list-len (& decls)) 16)
          (= (ast-decl-path-list-len (& paths)) 16)
          (= (ast-decl-module-list-len (& modules)) 16)
          (compiler-ast-decl-list-module-name? decls 0 "m0")
          (compiler-ast-decl-list-module-name? decls 7 "m7")
          (compiler-ast-decl-list-module-name? decls 15 "m15")
          (compiler-ast-decl-list-module-name? tail 0 "m1")
          (string.eq (ast-decl-path-list-get (& paths) 0 "") "p0")
          (string.eq (ast-decl-path-list-get (& paths) 15 "") "p15")
          (string.eq (ast-decl-module-list-get (& modules) 0 "") "m0")
          (string.eq (ast-decl-module-list-get (& modules) 15 "") "m15"))))))

(define (compiler-ast-decl-cons-pure-smoke?) : bool
  (let
    [tail : AstDeclList
      (ast-decl-cons (ast-decl-module "tail") (ast-decl-list-new))]
    [left : AstDeclList (ast-decl-cons (ast-decl-module "left") tail)]
    [right : AstDeclList (ast-decl-cons (ast-decl-module "right") tail)]
    (and
      (compiler-ast-decl-list-module-name? left 0 "left")
      (compiler-ast-decl-list-module-name? left 1 "tail")
      (compiler-ast-decl-list-module-name? right 0 "right")
      (compiler-ast-decl-list-module-name? right 1 "tail"))))

(define (main) : i64
  (begin
    (unless (= (compiler-ast-smoke) 23) (return 2))
    (unless (compiler-ast-state-owned-node-pools-smoke?) (return 3))
    (unless (compiler-ast-active-context-sync-smoke?) (return 4))
    (unless (compiler-ast-program-compaction-smoke?) (return 5))
    (unless (compiler-ast-decl-cons-growth-smoke?) (return 6))
    (unless (compiler-ast-decl-cons-pure-smoke?) (return 7))
    (unless (compiler-ast-program-compaction-string-payloads-smoke?) (return 8))
    42))