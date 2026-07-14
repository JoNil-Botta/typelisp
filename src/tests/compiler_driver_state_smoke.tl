(import stdlib.string)
(import stdlib.io)
(import stdlib.arena)
(import stdlib.vector)
(import (vector String) as svec)
(import "../compiler_driver_core.tl")
(import "../compiler_lower.tl")
(import "../compiler_clone.tl")
(import "../compiler_specialize.tl")
(import "../compiler_ctfe.tl")
(import sym_i64_env)
(import (hashmap i64 i64) as lower_i64_i64_map)

(define (compiler-driver-state-smoke-expr-push
  [pool : AstExprNodePoolState]
  [value : i64]) : AstExprNodePoolState
  (match (ast-expr-node-pool-state-push
    pool
    (AstExpr.Literal (ast-lit-int value)))
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
    [(AstExpr.Literal lit)
      (match lit
        [(AstLiteral.Int value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-driver-state-smoke-type-i64?
  [pool : AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast-type-node-pool-state-get pool id)
    [(AstType.I64) true]
    [_ false]))

(define (compiler-driver-state-smoke-type-char?
  [pool : AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast-type-node-pool-state-get pool id)
    [(AstType.Char) true]
    [_ false]))

(define (compiler-driver-state-smoke-global-expr-int?
  [id : i64]
  [expected : i64]) : bool
  (match (ast-node-get id)
    [(AstExpr.Literal lit)
      (match lit
        [(AstLiteral.Int value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-driver-state-smoke-global-type-i64? [id : i64]) : bool
  (match (ty-node-get id)
    [(AstType.I64) true]
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

(define (compiler-driver-state-smoke-reset-flags-isolated?) : bool
  (let
    [state-cached : CompilerDriverState
      (compiler-driver-state-session-cache-enable (compiler-driver-state-new))]
    [state-plain : CompilerDriverState (compiler-driver-state-new)]
    [state-no-program-cache : CompilerDriverState
      (compiler-driver-state-session-program-cache-disable
        (compiler-driver-state-new))]
    [ok : bool true]
    (begin
      (compiler-load-session-cache-disable-for-test!)
      (compiler-driver-state-reset-file-state! state-cached)
      (unless (compiler-load-session-cache-enabled?) (set! ok false))
      (compiler-load-session-floors-set! 2 3 4)
      (compiler-driver-state-capture-session-floors! state-cached)
      (compiler-driver-state-apply-session-flags! state-plain)
      (unless (= (compiler-load-session-ast-floor-value) 0) (set! ok false))
      (unless (= (compiler-load-session-ty-floor-value) 0) (set! ok false))
      (unless (= (compiler-load-session-intern-floor-value) 0) (set! ok false))
      (compiler-driver-state-apply-session-flags! state-cached)
      (unless (= (compiler-load-session-ast-floor-value) 2) (set! ok false))
      (unless (= (compiler-load-session-ty-floor-value) 3) (set! ok false))
      (unless (= (compiler-load-session-intern-floor-value) 4) (set! ok false))
      (compiler-load-session-floors-set! 0 0 0)
      (compiler-driver-state-capture-session-floors! state-cached)
      (compiler-driver-state-reset-file-state! state-plain)
      (unless (not (compiler-load-session-cache-enabled?)) (set! ok false))
      (compiler-driver-state-reset-file-state! state-cached)
      (unless (compiler-load-session-cache-enabled?) (set! ok false))
      (compiler-driver-state-reset-file-state! state-no-program-cache)
      (unless
        (not (compiler-load-session-program-cache-enabled?))
        (set! ok false))
      (compiler-driver-state-reset-file-state! state-plain)
      (unless (compiler-load-session-program-cache-enabled?) (set! ok false))
      (compiler-load-session-cache-disable-for-test!)
      ok)))

(define (compiler-driver-state-smoke-load-session-storage-isolated?) : bool
  (let
    [state-a : CompilerDriverState
      (compiler-driver-state-session-cache-enable (compiler-driver-state-new))]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [program : AstProgram (ast-program (ast-decl-list-new))]
    [ok : bool true]
    (begin
      (compiler-driver-state-apply-session-flags! state-a)
      (compiler-load-program-cache-clear!)
      (unless
        (compiler-load-program-cache-store "state-key" program)
        (set! ok false))
      (compiler-load-runtime-prelude-cache-store
        "prelude-key"
        (ast-decl-list-new)
        (ast-decl-path-list-new)
        (ast-decl-module-list-new)
        (sym_i64_env.sym-i64-empty))
      (compiler-load-session-floors-set! 2 3 4)
      (compiler-driver-state-apply-session-flags! state-b)
      (unless (not (compiler-load-session-cache-enabled?)) (set! ok false))
      (unless (= (compiler-load-session-ast-floor-value) 0) (set! ok false))
      (unless (= (compiler-load-session-ty-floor-value) 0) (set! ok false))
      (unless (= (compiler-load-session-intern-floor-value) 0) (set! ok false))
      (unless
        (= (compiler-load-program-cache-store-count-value) 0)
        (set! ok false))
      (match (compiler-load-program-cache-lookup "state-key")
        [(CompilerLoadProgramCacheMiss) unit]
        [(CompilerLoadProgramCacheHit _) (set! ok false)])
      (match (compiler-load-runtime-prelude-cache-lookup "prelude-key")
        [(CompilerLoadPreludeCacheMiss) unit]
        [(CompilerLoadPreludeCacheHit _ _ _ _) (set! ok false)])
      (compiler-driver-state-apply-session-flags! state-a)
      (unless (compiler-load-session-cache-enabled?) (set! ok false))
      (unless (= (compiler-load-session-ast-floor-value) 2) (set! ok false))
      (unless (= (compiler-load-session-ty-floor-value) 3) (set! ok false))
      (unless (= (compiler-load-session-intern-floor-value) 4) (set! ok false))
      (unless
        (= (compiler-load-program-cache-store-count-value) 1)
        (set! ok false))
      (match (compiler-load-program-cache-lookup "state-key")
        [(CompilerLoadProgramCacheHit _) unit]
        [(CompilerLoadProgramCacheMiss) (set! ok false)])
      (match (compiler-load-runtime-prelude-cache-lookup "prelude-key")
        [(CompilerLoadPreludeCacheHit _ _ _ _) unit]
        [(CompilerLoadPreludeCacheMiss) (set! ok false)])
      (compiler-load-session-cache-disable-for-test!)
      ok)))

(define (compiler-driver-state-smoke-pools-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [expr-a0 : AstExprNodePoolState
      (array-ref (struct-get state-a expr-pool) 0)]
    [expr-a-id0 : i64 (ast-expr-node-pool-state-mark expr-a0)]
    [expr-a1 : AstExprNodePoolState
      (compiler-driver-state-smoke-expr-push expr-a0 7)]
    [expr-a-id1 : i64 (ast-expr-node-pool-state-mark expr-a1)]
    [expr-a2 : AstExprNodePoolState
      (compiler-driver-state-smoke-expr-push expr-a1 8)]
    [expr-b0 : AstExprNodePoolState
      (array-ref (struct-get state-b expr-pool) 0)]
    [expr-b-mark : i64 (ast-expr-node-pool-state-mark expr-b0)]
    [expr-b1 : AstExprNodePoolState
      (compiler-driver-state-smoke-expr-push expr-b0 11)]
    [expr-b-reset : AstExprNodePoolState
      (ast-expr-node-pool-state-reset-to-mark expr-b1 expr-b-mark)]
    [expr-b-id : i64 (ast-expr-node-pool-state-mark expr-b-reset)]
    [expr-b2 : AstExprNodePoolState
      (compiler-driver-state-smoke-expr-push expr-b-reset 12)]
    [type-a0 : AstTypeNodePoolState
      (array-ref (struct-get state-a type-pool) 0)]
    [type-a-id0 : i64 (ast-type-node-pool-state-mark type-a0)]
    [type-a1 : AstTypeNodePoolState
      (compiler-driver-state-smoke-type-push type-a0 (AstType.I64))]
    [type-a-id1 : i64 (ast-type-node-pool-state-mark type-a1)]
    [type-a2 : AstTypeNodePoolState
      (compiler-driver-state-smoke-type-push type-a1 (AstType.String))]
    [type-b0 : AstTypeNodePoolState
      (array-ref (struct-get state-b type-pool) 0)]
    [type-b-mark : i64 (ast-type-node-pool-state-mark type-b0)]
    [type-b1 : AstTypeNodePoolState
      (compiler-driver-state-smoke-type-push type-b0 (AstType.Bool))]
    [type-b-reset : AstTypeNodePoolState
      (ast-type-node-pool-state-reset-to-mark type-b1 type-b-mark)]
    [type-b-id : i64 (ast-type-node-pool-state-mark type-b-reset)]
    [type-b2 : AstTypeNodePoolState
      (compiler-driver-state-smoke-type-push type-b-reset (AstType.Char))]
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

(define (compiler-driver-state-smoke-type-dedup-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [type-a0 : AstTypeNodePoolState
      (array-ref (struct-get state-a type-pool) 0)]
    [type-b0 : AstTypeNodePoolState
      (array-ref (struct-get state-b type-pool) 0)]
    (match (ast-type-node-pool-state-push type-a0 (AstType.I64))
      [(AstTypeNodePoolPushOk type-a1 a-id)
        (match (ast-type-node-pool-state-push type-b0 (AstType.I64))
          [(AstTypeNodePoolPushOk type-b1 b-id)
            (match (ast-type-node-pool-state-push type-a1 (AstType.I64))
              [(AstTypeNodePoolPushOk type-a2 a-dupe-id)
                (match (ast-type-node-pool-state-push type-b1 (AstType.I64))
                  [(AstTypeNodePoolPushOk type-b2 b-dupe-id)
                    (and
                      (= a-id 0)
                      (= b-id 0)
                      (= a-dupe-id a-id)
                      (= b-dupe-id b-id)
                      (= (ast-type-node-pool-state-len type-a2) 1)
                      (= (ast-type-node-pool-state-len type-b2) 1)
                      (compiler-driver-state-smoke-type-i64? type-a2 a-id)
                      (compiler-driver-state-smoke-type-i64? type-b2 b-id))])])])])))

(define (compiler-driver-state-smoke-context-expr-unspan
  [pools : AstNodePoolContext]
  [expr : AstExpr]) : AstExpr
  (match expr
    [(AstExpr.Spanned inner-id _)
      (compiler-driver-state-smoke-context-expr-unspan
        pools
        (ast-node-pool-context-expr-get pools inner-id))]
    [_ expr]))

(define (compiler-driver-state-smoke-context-type-u8?
  [pools : AstNodePoolContext]
  [id : i64]) : bool
  (match (ast-node-pool-context-type-get pools id)
    [(AstType.U8) true]
    [_ false]))

(define (compiler-driver-state-smoke-context-bool-lit?
  [pools : AstNodePoolContext]
  [id : i64]
  [want : bool]) : bool
  (match (ast-node-pool-context-expr-get pools id)
    [(AstExpr.Literal (AstLiteral.Bool value)) (= value want)]
    [_ false]))

(define (compiler-driver-state-smoke-context-int-lit?
  [pools : AstNodePoolContext]
  [id : i64]
  [want : i64]) : bool
  (match (ast-node-pool-context-expr-get pools id)
    [(AstExpr.Literal (AstLiteral.Int value _)) (= value want)]
    [_ false]))

(define (compiler-driver-state-smoke-lower-state-instrs [state : LowerState]) : CompilerIrInstrList
  (match state
    [(LowerState.State _ _ _ _ instrs _ _ _ _ _ _ _ _ _ _)
      (compiler-ir-instr-builder-to-list instrs)]))

(define (compiler-driver-state-smoke-instr-i64-mov?
  [instr : CompilerIrInstr]
  [want : i64]) : bool
  (match instr
    [(CompilerIrInstr.Mov _ (CompilerIrValue.I64 got) _) (= got want)]
    [_ false]))

(define (compiler-driver-state-smoke-instrs-contain-i64-mov?
  [instrs : CompilerIrInstrList]
  [want : i64]) : bool
  (match instrs
    [(CompilerIrInstrList.Nil) false]
    [(CompilerIrInstrList.Cons instr rest)
      (or
        (compiler-driver-state-smoke-instr-i64-mov? instr want)
        (compiler-driver-state-smoke-instrs-contain-i64-mov?
          (box-get rest)
          want))]))

(define (compiler-driver-state-smoke-lower-args-from-state-a?
  [state : LowerState]) : bool
  (let
    [instrs : CompilerIrInstrList
      (compiler-driver-state-smoke-lower-state-instrs state)]
    (and
      (compiler-driver-state-smoke-instrs-contain-i64-mov? instrs 3)
      (compiler-driver-state-smoke-instrs-contain-i64-mov? instrs 5)
      (not (compiler-driver-state-smoke-instrs-contain-i64-mov? instrs 3000))
      (not (compiler-driver-state-smoke-instrs-contain-i64-mov? instrs 5000)))))

(define (compiler-driver-state-smoke-context-if-bool-lits?
  [pools : AstNodePoolContext]
  [id : i64]) : bool
  (match (ast-node-pool-context-expr-get pools id)
    [(AstExpr.If cond then-branch else-branch)
      (and
        (compiler-driver-state-smoke-context-bool-lit? pools cond true)
        (compiler-driver-state-smoke-context-bool-lit? pools then-branch true)
        (compiler-driver-state-smoke-context-bool-lit? pools else-branch false))]
    [_ false]))

(define (compiler-driver-state-smoke-context-ptr-null-u8?
  [pools : AstNodePoolContext]
  [id : i64]) : bool
  (match (compiler-driver-state-smoke-context-expr-unspan
    pools
    (ast-node-pool-context-expr-get pools id))
    [(AstExpr.PtrNull (AstType.Ptr inner-id))
      (compiler-driver-state-smoke-context-type-u8? pools inner-id)]
    [_ false]))

(define (compiler-driver-state-smoke-note-main-ptr-u8!
  [pools : AstNodePoolContext]
  [program : AstProgram]
  [body-cell : (Array i64)]
  [type-cell : (Array i64)]) : bool
  (match program
    [(AstProgram.Program decls-box)
      (match (ast-decl-list-step (box-get decls-box))
        [(AstDeclListStep.Cons
            (AstDecl.DefFn _ _ (AstType.Ptr inner-id) body-id _)
            _)
          (begin
            (array-set! body-cell 0 body-id)
            (array-set! type-cell 0 inner-id)
            (and
              (compiler-driver-state-smoke-context-type-u8? pools inner-id)
              (compiler-driver-state-smoke-context-ptr-null-u8? pools body-id)))]
        [_ false])]))

(define (compiler-driver-state-smoke-parse-pools-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [body-cell : (Array i64) (make-array i64 1)]
    [type-cell : (Array i64) (make-array i64 1)]
    [ok : bool true]
    (begin
      (array-set! body-cell 0 (- 0 1))
      (array-set! type-cell 0 (- 0 1))
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        (begin
          (match (parse-ast-source-diagnostic-with-cfg-and-pools
            "state-a.tl"
            "(define (main) : (Ptr u8) (ptr-null : (Ptr u8)))"
            (compiler-cfg-empty)
            pools-a)
            [(ResultAstProgramDiagnostic.Ok program)
              (unless
                (compiler-driver-state-smoke-note-main-ptr-u8!
                  pools-a
                  program
                  body-cell
                  type-cell)
                (set! ok false))]
            [(ResultAstProgramDiagnostic.Err _) (set! ok false)])
          (match (parse-ast-source-diagnostic-with-cfg-and-pools
            "state-b.tl"
            "(define (main) : (Ptr i64) (ptr-null : (Ptr i64)))"
            (compiler-cfg-empty)
            pools-b)
            [(ResultAstProgramDiagnostic.Ok _) unit]
            [(ResultAstProgramDiagnostic.Err _) (set! ok false)])
          (compiler-driver-state-reset-file-state! state-b)
          (unless (>= (array-ref body-cell 0) 0) (set! ok false))
          (unless (>= (array-ref type-cell 0) 0) (set! ok false))
          (unless
            (compiler-driver-state-smoke-context-type-u8?
              pools-a
              (array-ref type-cell 0))
            (set! ok false))
          (unless
            (compiler-driver-state-smoke-context-ptr-null-u8?
              pools-a
              (array-ref body-cell 0))
            (set! ok false))
          ok)))))

(define (compiler-driver-state-smoke-clone-program
  [pools : AstNodePoolContext]
  [name : String]) : AstProgram
  (let
    [elem : i64 (ast-node-pool-context-type-push pools (AstType.I64))]
    [field : AstFieldDef
      (ast-field-def "items" (AstType.Array elem 2) (AstFieldCleanup.No))]
    [decl : AstDecl
      (ast-decl-def-struct
        name
        (AstStructRepr.Default)
        (AstStructCleanup.No)
        (ast-field-def-cons field (ast-field-def-list-new)))]
    (ast-program (ast-decl-cons decl (ast-decl-list-new)))))

(define (compiler-driver-state-smoke-clone-generated-ctor?
  [pools : AstNodePoolContext]
  [program : AstProgram]
  [name : String]) : bool
  (match program
    [(AstProgram.Program decls-box)
      (match (ast-decl-list-step (box-get decls-box))
        [(AstDeclListStep.Cons _ rest)
          (match (ast-decl-list-step rest)
            [(AstDeclListStep.Cons decl tail)
              (match (ast-decl-list-step tail)
                [(AstDeclListStep.Nil)
                  (match decl
                    [(AstDecl.DefFn fn-name _ _ body _)
                      (and
                        (string.eq
                          (intern-str fn-name)
                          (clone-helper-name name))
                        (match (ast-node-pool-context-expr-get pools body)
                          [(AstExpr.Call callee _)
                            (match (ast-node-pool-context-expr-get pools callee)
                              [(AstExpr.Var ctor)
                                (string.eq (intern-str ctor) name)]
                              [_ false])]
                          [_ false]))]
                    [_ false])]
                [_ false])]
            [_ false])]
        [_ false])]))

(define (compiler-driver-state-smoke-clone-dest-program
  [pools : AstNodePoolContext]
  [name : String]) : AstProgram
  (let
    [_source-decoy-type : i64
      (ast-node-pool-context-type-push pools (AstType.Bool))]
    [elem : i64 (ast-node-pool-context-type-push pools (AstType.I64))]
    [_source-decoy-expr : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Literal (ast-lit-int -1)))]
    [value : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Literal (ast-lit-int 91)))]
    [field : AstFieldDef
      (ast-field-def "items" (AstType.Array elem 2) (AstFieldCleanup.No))]
    [struct-decl : AstDecl
      (ast-decl-def-struct
        name
        (AstStructRepr.Default)
        (AstStructCleanup.No)
        (ast-field-def-cons field (ast-field-def-list-new)))]
    [value-decl : AstDecl (ast-decl-def "kept" AstMaybeType.No value)]
    (ast-program
      (ast-decl-cons struct-decl (ast-decl-cons value-decl (ast-decl-list-new))))))

(define (compiler-driver-state-smoke-clone-helper-decl?
  [pools : AstNodePoolContext]
  [decl : AstDecl]
  [name : String]) : bool
  (match decl
    [(AstDecl.DefFn fn-name _ _ body _)
      (and
        (string.eq (intern-str fn-name) (clone-helper-name name))
        (match (ast-node-pool-context-expr-get pools body)
          [(AstExpr.Call callee _)
            (match (ast-node-pool-context-expr-get pools callee)
              [(AstExpr.Var ctor) (string.eq (intern-str ctor) name)]
              [_ false])]
          [_ false]))]
    [_ false]))

(define (compiler-driver-state-smoke-clone-helper-in-decls?
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [name : String]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) false]
    [(AstDeclListStep.Cons decl rest)
      (if (compiler-driver-state-smoke-clone-helper-decl? pools decl name)
        true
        (compiler-driver-state-smoke-clone-helper-in-decls? pools rest name))]))

(define (compiler-driver-state-smoke-clone-dest-field-remapped?
  [pools : AstNodePoolContext]
  [decl : AstDecl]
  [name : String]) : bool
  (match decl
    [(AstDecl.DefStruct decl-name _ _ fields)
      (and
        (string.eq (intern-str decl-name) name)
        (= (ast-field-def-list-len (& fields)) 1)
        (match (ast-field-def-list-get (& fields) 0 (ast-field-def-fallback))
          [(AstFieldDef.Def field-name ty _)
            (and
              (string.eq (intern-str field-name) "items")
              (match ty
                [(AstType.Array elem count)
                  (and
                    (= elem 0)
                    (= count 2)
                    (match (ast-node-pool-context-type-get pools elem)
                      [(AstType.I64) true]
                      [_ false]))]
                [_ false]))]))]
    [_ false]))

(define (compiler-driver-state-smoke-clone-dest-decls-remapped?
  [pools : AstNodePoolContext]
  [program : AstProgram]) : bool
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (and
          (= (ast-decl-list-len (& decls)) 3)
          (match (ast-decl-list-step decls)
            [(AstDeclListStep.Cons first rest)
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Cons second helper-rest)
                  (and
                    (compiler-driver-state-smoke-clone-dest-field-remapped?
                      pools
                      first
                      "CloneDest")
                    (match second
                      [(AstDecl.Def name _ body)
                        (and
                          (string.eq (intern-str name) "kept")
                          (= body 0)
                          (compiler-driver-state-smoke-context-int-lit?
                            pools
                            body
                            91))]
                      [_ false])
                    (compiler-driver-state-smoke-clone-helper-in-decls?
                      pools
                      helper-rest
                      "CloneDest"))]
                [_ false])]
            [_ false])))]))

(define (compiler-driver-state-smoke-clone-augment-dest-pools?) : bool
  (let
    [state-source : CompilerDriverState (compiler-driver-state-new)]
    [state-dest : CompilerDriverState (compiler-driver-state-new)]
    (begin
      (compiler-driver-state-reset-file-state! state-source)
      (compiler-driver-state-reset-file-state! state-dest)
      (let
        [source-pools : AstNodePoolContext
          (compiler-driver-state-pool-context state-source)]
        [dest-pools : AstNodePoolContext
          (compiler-driver-state-pool-context state-dest)]
        [program : AstProgram
          (compiler-driver-state-smoke-clone-dest-program
            source-pools
            "CloneDest")]
        [source-expr-len-before : i64
          (ast-node-pool-context-expr-len source-pools)]
        [source-type-len-before : i64
          (ast-node-pool-context-type-len source-pools)]
        [dest-decoy-expr : i64
          (ast-node-pool-context-expr-push
            dest-pools
            (AstExpr.Literal (ast-lit-int 1234)))]
        [dest-decoy-type : i64
          (ast-node-pool-context-type-push dest-pools (AstType.Bool))]
        [roots : CloneNameList
          (CloneNameList.Cons "CloneDest" (box (CloneNameList.Nil)))]
        [compacted : AstProgramCompaction
          (clone-augment-program-with-roots-from-pools
            source-pools
            dest-pools
            program
            roots)]
        (match compacted
          [(AstProgramCompaction checked-program checked-pools)
            (and
              (= dest-decoy-expr 0)
              (= dest-decoy-type 0)
              (=
                source-expr-len-before
                (ast-node-pool-context-expr-len source-pools))
              (=
                source-type-len-before
                (ast-node-pool-context-type-len source-pools))
              (compiler-driver-state-smoke-context-int-lit? checked-pools 0 91)
              (compiler-driver-state-smoke-clone-dest-decls-remapped?
                checked-pools
                checked-program))])))))

(define (compiler-driver-state-smoke-clone-pools-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        [program-a : AstProgram
          (compiler-driver-state-smoke-clone-program pools-a "CloneA")]
        [program-b : AstProgram
          (compiler-driver-state-smoke-clone-program pools-b "CloneB")]
        [augmented-a : AstProgram
          (clone-augment-program-with-pools pools-a program-a)]
        [augmented-b : AstProgram
          (clone-augment-program-with-pools pools-b program-b)]
        [generated-b-ok : bool
          (compiler-driver-state-smoke-clone-generated-ctor?
            pools-b
            augmented-b
            "CloneB")]
        (begin
          (compiler-driver-state-reset-file-state! state-b)
          (and
            (> (ast-node-pool-context-expr-len pools-a) 0)
            generated-b-ok
            (compiler-driver-state-smoke-clone-generated-ctor?
              pools-a
              augmented-a
              "CloneA")))))))

(define (compiler-driver-state-smoke-specialize-source [n : i64]) : String
  (string.append
    "(define (scale [comptime n : i64] [x : i64]) : i64 (+ x n))
(define (main) : i64 (scale "
    (string.append (string.int->string n) " 35))")))

(define (compiler-driver-state-smoke-specialized-scale-body-ok?
  [pools : AstNodePoolContext]
  [body : i64]) : bool
  (match (compiler-driver-state-smoke-context-expr-unspan
    pools
    (ast-node-pool-context-expr-get pools body))
    [(AstExpr.Binary op left right)
      (match op
        [(AstBinOp.Add)
          (match (compiler-driver-state-smoke-context-expr-unspan
            pools
            (ast-node-pool-context-expr-get pools left))
            [(AstExpr.Var name)
              (if (string.eq (intern-str name) "x")
                (match (compiler-driver-state-smoke-context-expr-unspan
                  pools
                  (ast-node-pool-context-expr-get pools right))
                  [(AstExpr.Literal lit)
                    (match lit
                      [(AstLiteral.Int value _) (= value 7)]
                      [_ false])]
                  [_ false])
                false)]
            [_ false])]
        [_ false])]
    [_ false]))

(define (compiler-driver-state-smoke-specialized-scale-decls-ok?
  [pools : AstNodePoolContext]
  [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) false]
    [(AstDeclListStep.Cons decl rest)
      (match decl
        [(AstDecl.DefFn name _ _ body _)
          (if (string.eq (intern-str name) "__tl_specialized_scale_i64_7_none")
            (compiler-driver-state-smoke-specialized-scale-body-ok? pools body)
            (compiler-driver-state-smoke-specialized-scale-decls-ok? pools rest))]
        [_ (compiler-driver-state-smoke-specialized-scale-decls-ok? pools rest)])]))

(define (compiler-driver-state-smoke-specialized-scale-program-ok?
  [pools : AstNodePoolContext]
  [program : AstProgram]) : bool
  (match program
    [(AstProgram.Program decls-box)
      (compiler-driver-state-smoke-specialized-scale-decls-ok?
        pools
        (box-get decls-box))]))

(define (compiler-driver-state-smoke-specialize-pools-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [ok : bool true]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        (match (parse-ast-source-diagnostic-with-cfg-and-pools
          "spec-a.tl"
          (compiler-driver-state-smoke-specialize-source 7)
          (compiler-cfg-empty)
          pools-a)
          [(ResultAstProgramDiagnostic.Ok program-a)
            (match (parse-ast-source-diagnostic-with-cfg-and-pools
              "spec-b.tl"
              (compiler-driver-state-smoke-specialize-source 11)
              (compiler-cfg-empty)
              pools-b)
              [(ResultAstProgramDiagnostic.Ok _)
                (begin
                  (compiler-driver-state-install-pools! state-b)
                  (match (compiler-specialize-program-with-pools
                    program-a
                    pools-a)
                    [(ResultSpecProgram.Ok specialized-a)
                      (begin
                        (compiler-driver-state-reset-file-state! state-b)
                        (unless
                          (compiler-driver-state-smoke-specialized-scale-program-ok?
                            pools-a
                            specialized-a)
                          (set! ok false))
                        (unless
                          (> (ast-node-pool-context-expr-len pools-a) 0)
                          (set! ok false))
                        ok)]
                    [(ResultSpecProgram.Err _) false]))]
              [(ResultAstProgramDiagnostic.Err _) false])]
          [(ResultAstProgramDiagnostic.Err _) false])))))

(define (compiler-driver-state-smoke-active-pools-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [ok : bool true]
    (begin
      (compiler-driver-state-install-pools! state-a)
      (let
        [expr-a-id : i64 (ast-node-push (AstExpr.Literal (ast-lit-int 7)))]
        [type-a-id : i64 (ty-node-push (AstType.I64))]
        (begin
          (compiler-driver-state-capture-active-pools! state-a)
          (compiler-driver-state-install-pools! state-b)
          (let
            [expr-b-id : i64 (ast-node-push (AstExpr.Literal (ast-lit-int 11)))]
            [type-b-id : i64 (ty-node-push (AstType.Char))]
            (begin
              (compiler-driver-state-capture-active-pools! state-b)
              (compiler-driver-state-reset-file-state! state-b)
              (compiler-driver-state-install-pools! state-a)
              (unless (= (ast-node-pool-len) 1) (set! ok false))
              (unless (= (ty-node-pool-len) 1) (set! ok false))
              (unless
                (compiler-driver-state-smoke-global-expr-int? expr-a-id 7)
                (set! ok false))
              (unless
                (compiler-driver-state-smoke-global-type-i64? type-a-id)
                (set! ok false))
              (compiler-driver-state-install-pools! state-b)
              (unless (= (ast-node-pool-len) 0) (set! ok false))
              (unless (= (ty-node-pool-len) 0) (set! ok false))
              (unless (= expr-b-id 0) (set! ok false))
              (unless (= type-b-id 0) (set! ok false))
              ok)))))))

(define (compiler-driver-state-smoke-ctfe-pools-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [ok : bool true]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [env-a : CtfeEnv (ctfe-env-empty-with-pools pools-a)]
        [cond-id : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (AstLiteral.Bool true)))]
        [then-id : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 7)))]
        [else-id : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 9)))]
        [if-id : i64 (ast-expr-if-with-pools pools-a cond-id then-id else-id)]
        [quote-cond-id : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (AstLiteral.Bool true)))]
        [quote-false-id : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (AstLiteral.Bool false)))]
        [quote-var-id : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Var (intern "replacement")))]
        [quote-unquote-id : i64
          (ast-expr-unquote-with-pools pools-a quote-var-id)]
        [quote-if-id : i64
          (ast-expr-if-with-pools
            pools-a
            quote-unquote-id
            quote-cond-id
            quote-false-id)]
        [quasiquote-id : i64
          (ast-expr-quasiquote-with-pools pools-a quote-if-id)]
        [quote-env : CtfeEnv
          (ctfe-env-extend
            env-a
            "replacement"
            (CompilerCtfeValue.Expr quote-cond-id (AstType.Bool)))]
        [quote-len-before : i64 (ast-node-pool-context-expr-len pools-a)]
        (begin
          (compiler-driver-state-install-pools! state-b)
          (match (compiler-ctfe-eval
            (ast-node-pool-context-expr-get pools-a if-id)
            env-a
            (ctfe-fuel-limit))
            [(ResultCtfe.Ok value _)
              (match value
                [(CompilerCtfeValue.I64 n) (unless (= n 7) (set! ok false))]
                [_ (set! ok false)])]
            [(ResultCtfe.Err _) (set! ok false)])
          (match (compiler-ctfe-eval
            (ast-node-pool-context-expr-get pools-a quasiquote-id)
            quote-env
            (ctfe-fuel-limit))
            [(ResultCtfe.Ok value _)
              (match value
                [(CompilerCtfeValue.Expr node ty)
                  (begin
                    (unless
                      (ctfe-type-eq-in-env quote-env ty (AstType.Bool))
                      (set! ok false))
                    (unless (>= node quote-len-before) (set! ok false))
                    (unless
                      (< node (ast-node-pool-context-expr-len pools-a))
                      (set! ok false))
                    (compiler-driver-state-reset-file-state! state-b)
                    (unless
                      (compiler-driver-state-smoke-context-if-bool-lits?
                        pools-a
                        node)
                      (set! ok false)))]
                [_ (set! ok false)])]
            [(ResultCtfe.Err _) (set! ok false)])
          ok)))))

(define (compiler-driver-state-smoke-typecheck-macro-source [n : i64]) : String
  (string.append
    "(define (main) : (Ptr u8) (ptr-null : (Ptr u8)))
(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(define (use-macro) : i64 (if (and2 true true) "
    (string.append (string.int->string n) " 0))")))

(define (compiler-driver-state-smoke-typecheck-macro-with-pools
  [path : String]
  [source : String]
  [pools : AstNodePoolContext]
  [body-cell : (Array i64)]
  [type-cell : (Array i64)]
  [before-cell : (Array i64)]
  [after-cell : (Array i64)]) : bool
  (match (parse-ast-source-diagnostic-with-cfg-and-pools
    path
    source
    (compiler-cfg-empty)
    pools)
    [(ResultAstProgramDiagnostic.Ok program)
      (if (compiler-driver-state-smoke-note-main-ptr-u8!
        pools
        program
        body-cell
        type-cell)
        (begin
          (array-set! before-cell 0 (ast-node-pool-context-expr-len pools))
          (match (typecheck-compiler-program-with-paths-cache-and-pools
            program
            (ast-decl-path-list-new)
            (svec.new)
            (tc-prefix-default-cache-scope)
            pools)
            [(ResultCompilerTypecheck.Ok _)
              (begin
                (array-set! after-cell 0 (ast-node-pool-context-expr-len pools))
                true)]
            [(ResultCompilerTypecheck.Err _) false]))
        false)]
    [(ResultAstProgramDiagnostic.Err _) false]))

(define (compiler-driver-state-smoke-typecheck-macro-pools-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [body-a-cell : (Array i64) (make-array i64 1)]
    [type-a-cell : (Array i64) (make-array i64 1)]
    [before-a-cell : (Array i64) (make-array i64 1)]
    [after-a-cell : (Array i64) (make-array i64 1)]
    [body-b-cell : (Array i64) (make-array i64 1)]
    [type-b-cell : (Array i64) (make-array i64 1)]
    [before-b-cell : (Array i64) (make-array i64 1)]
    [after-b-cell : (Array i64) (make-array i64 1)]
    [ok : bool true]
    (begin
      (array-set! body-a-cell 0 (- 0 1))
      (array-set! type-a-cell 0 (- 0 1))
      (array-set! before-a-cell 0 (- 0 1))
      (array-set! after-a-cell 0 (- 0 1))
      (array-set! body-b-cell 0 (- 0 1))
      (array-set! type-b-cell 0 (- 0 1))
      (array-set! before-b-cell 0 (- 0 1))
      (array-set! after-b-cell 0 (- 0 1))
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        (begin
          (compiler-driver-state-install-pools! state-b)
          (unless
            (compiler-driver-state-smoke-typecheck-macro-with-pools
              "tc-state-a.tl"
              (compiler-driver-state-smoke-typecheck-macro-source 7)
              pools-a
              body-a-cell
              type-a-cell
              before-a-cell
              after-a-cell)
            (set! ok false))
          (compiler-driver-state-reset-file-state! state-b)
          (unless
            (compiler-driver-state-smoke-context-type-u8?
              pools-a
              (array-ref type-a-cell 0))
            (set! ok false))
          (unless
            (compiler-driver-state-smoke-context-ptr-null-u8?
              pools-a
              (array-ref body-a-cell 0))
            (set! ok false))
          (unless
            (> (array-ref after-a-cell 0) (array-ref before-a-cell 0))
            (set! ok false))
          (compiler-driver-state-install-pools! state-a)
          (unless
            (compiler-driver-state-smoke-typecheck-macro-with-pools
              "tc-state-b.tl"
              (compiler-driver-state-smoke-typecheck-macro-source 11)
              pools-b
              body-b-cell
              type-b-cell
              before-b-cell
              after-b-cell)
            (set! ok false))
          (compiler-driver-state-capture-active-pools! state-b)
          (compiler-driver-state-reset-file-state! state-b)
          (unless
            (compiler-driver-state-smoke-context-type-u8?
              pools-a
              (array-ref type-a-cell 0))
            (set! ok false))
          (unless
            (compiler-driver-state-smoke-context-ptr-null-u8?
              pools-a
              (array-ref body-a-cell 0))
            (set! ok false))
          (unless
            (> (array-ref after-b-cell 0) (array-ref before-b-cell 0))
            (set! ok false))
          ok)))))

(define (compiler-driver-state-smoke-builtins-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [state-a-ids-addr : i64
      (compiler-driver-state-builtin-ids-data-addr state-a)]
    [state-b-ids-addr : i64
      (compiler-driver-state-builtin-ids-data-addr state-b)]
    [ok : bool true]
    (begin
      (unless (not (= state-a-ids-addr state-b-ids-addr)) (set! ok false))
      (compiler-driver-state-install-builtins! state-a)
      (let
        [string-length-id : i64 (intern "__tl_string_length")]
        (begin
          (unless
            (compiler-driver-builtin-typecheck-string-length-id?
              string-length-id)
            (set! ok false))
          (compiler-driver-state-capture-active-builtins! state-a)
          (let
            [state-a-generation : i64
              (compiler-driver-state-builtin-generation state-a)]
            (begin
              (compiler-driver-state-install-builtins! state-b)
              (let
                [array-length-id : i64 (intern "array-length")]
                (begin
                  (unless
                    (compiler-driver-builtin-typecheck-array-length-id?
                      array-length-id)
                    (set! ok false))
                  (compiler-driver-state-capture-active-builtins! state-b)
                  (compiler-driver-state-reset-file-state! state-b)
                  (unless
                    (= (compiler-driver-state-builtin-generation state-b) -1)
                    (set! ok false))
                  (unless
                    (=
                      (compiler-driver-state-builtin-ids-data-addr state-b)
                      state-b-ids-addr)
                    (set! ok false))
                  (unless
                    (=
                      (compiler-driver-state-builtin-generation state-a)
                      state-a-generation)
                    (set! ok false))
                  (unless
                    (=
                      (compiler-driver-state-builtin-ids-data-addr state-a)
                      state-a-ids-addr)
                    (set! ok false))
                  (compiler-driver-state-install-builtins! state-a)
                  (let
                    [string-length-id-after-reset : i64
                      (intern "__tl_string_length")]
                    (begin
                      (unless
                        (compiler-driver-builtin-typecheck-string-length-id?
                          string-length-id-after-reset)
                        (set! ok false))
                      ok)))))))))))

(define (compiler-driver-state-smoke-builtins-scratch-capture-stable?) : bool
  (let
    [state : CompilerDriverState (compiler-driver-state-new)]
    [ok : bool true]
    (begin
      (compiler-driver-state-install-builtins! state)
      (let
        [before : i64 (compiler-driver-state-builtin-ids-data-addr state)]
        [string-length-id : i64 (intern "__tl_string_length")]
        (begin
          (unless
            (compiler-driver-builtin-typecheck-string-length-id?
              string-length-id)
            (set! ok false))
          (with-scratch (compiler-driver-state-capture-active-builtins! state))
          (let
            [after : i64 (compiler-driver-state-builtin-ids-data-addr state)]
            (begin
              (unless (= before after) (set! ok false))
              (compiler-driver-state-reset-builtins! state)
              (unless
                (= (compiler-driver-state-builtin-generation state) -1)
                (set! ok false))
              (unless
                (= (compiler-driver-state-builtin-ids-data-addr state) before)
                (set! ok false))
              (unless
                (compiler-driver-builtin-typecheck-string-length-id?
                  string-length-id)
                (set! ok false))
              (compiler-driver-state-capture-active-builtins! state)
              (unless
                (> (compiler-driver-state-builtin-generation state) -1)
                (set! ok false))
              ok)))))))

(define (compiler-driver-state-smoke-render-ok?
  [owner : InternIdProvenance]
  [id : i64]
  [expected : String]) : bool
  (match (intern-id-render owner id)
    [(InternIdRender.Ok text) (string.eq text expected)]
    [_ false]))

(define (compiler-driver-state-smoke-interns-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [a-address : (Box i64) (box 0)]
    [b-address : (Box i64) (box 0)]
    [ok : bool true]
    (begin
      (unless
        (not
          (=
            (compiler-driver-state-intern-pool-data-addr state-a)
            (compiler-driver-state-intern-pool-data-addr state-b)))
        (set! ok false))
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-install-interns! state-a)
      (intern-persistent-storage-enable!)
      (let
        [a-shared : i64
          (with-scratch
            (let
              [name : String
                (string.substring
                  "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss"
                  0
                  49)]
              (intern name)))]
        [a-only : i64
          (with-scratch
            (let
              [name : String
                (string.substring
                  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                  0
                  49)]
              (begin
                (set!
                  (box-get a-address)
                  (cast
                    (unsafe
                      (ptr->int (string-data (& name))))
                    : i64))
                (intern name))))]
        [a-mark : i64 (intern-pool-len)]
        [a-owner : InternIdProvenance (intern-id-provenance-capture)]
        (begin
          (compiler-driver-state-capture-active-interns! state-a)
          (compiler-driver-state-reset-file-state! state-b)
          (compiler-driver-state-install-interns! state-b)
          (intern-persistent-storage-enable!)
          (let
            ;; Insert the different name first so equal spellings receive
            ;; different numeric ids, while id 0 means different things in A/B.
            [b-only : i64
              (with-scratch
                (let
                  [name : String
                    (string.substring
                      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                      0
                      49)]
                  (begin
                    (set!
                      (box-get b-address)
                      (cast
                        (unsafe
                          (ptr->int (string-data (& name))))
                        : i64))
                    (intern name))))]
            [b-shared : i64
              (with-scratch
                (intern
                  (string.substring
                    "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss"
                    0
                    49)))]
            [b-owner : InternIdProvenance (intern-id-provenance-capture)]
            [b-generation : i64 (intern-generation)]
            (begin
              (compiler-driver-state-capture-active-interns! state-b)
              (unless
                (= (box-get a-address) (box-get b-address))
                (set! ok false))
              (unless (= a-shared 0) (set! ok false))
              (unless (= a-only 1) (set! ok false))
              (unless (= b-only 0) (set! ok false))
              (unless (= b-shared 1) (set! ok false))
              (unless
                (compiler-driver-state-smoke-render-ok?
                  b-owner
                  b-only
                  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
                (set! ok false))
              (match (intern-id-render a-owner a-only)
                [(InternIdRender.WrongOwner) unit]
                [_ (set! ok false)])
              (compiler-driver-state-install-interns! state-a)
              (unless
                (compiler-driver-state-smoke-render-ok?
                  a-owner
                  a-shared
                  "sssssssssssssssssssssssssssssssssssssssssssssssss")
                (set! ok false))
              (unless
                (compiler-driver-state-smoke-render-ok?
                  a-owner
                  a-only
                  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                (set! ok false))
              (match (intern-id-render b-owner b-only)
                [(InternIdRender.WrongOwner) unit]
                [_ (set! ok false)])
              (let
                [dropped : i64 (intern "drop-after-mark")]
                [before-reset : InternIdProvenance
                  (intern-id-provenance-capture)]
                (begin
                  (unless (= dropped a-mark) (set! ok false))
                  (intern-reset-to! a-mark)
                  (match (intern-id-render a-owner a-only)
                    [(InternIdRender.StaleGeneration) unit]
                    [_ (set! ok false)])
                  (match (intern-id-render before-reset dropped)
                    [(InternIdRender.StaleGeneration) unit]
                    [_ (set! ok false)])
                  (let
                    [a-fresh-owner : InternIdProvenance
                      (intern-id-provenance-capture)]
                    (begin
                      (unless
                        (compiler-driver-state-smoke-render-ok?
                          a-fresh-owner
                          a-only
                          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                        (set! ok false))
                      (match (intern-id-render a-fresh-owner dropped)
                        [(InternIdRender.InvalidId) unit]
                        [_ (set! ok false)]))))
                (compiler-driver-state-capture-active-interns! state-a)
                (compiler-driver-state-install-interns! state-b)
                (unless (= (intern-generation) b-generation) (set! ok false))
                (unless
                  (compiler-driver-state-smoke-render-ok?
                    b-owner
                    b-shared
                    "sssssssssssssssssssssssssssssssssssssssssssssssss")
                  (set! ok false))
                ;; Reset A through its owned state while B stays installed.
                (compiler-load-session-reset-interns-with-state!
                  (array-ref (struct-get state-a intern-state) 0))
                (unless (= (intern-generation) b-generation) (set! ok false))
                (unless
                  (compiler-driver-state-smoke-render-ok?
                    b-owner
                    b-only
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
                  (set! ok false))
                (compiler-driver-state-install-interns! state-a)
                (match (intern-id-render a-owner a-only)
                  [(InternIdRender.StaleGeneration) unit]
                  [_ (set! ok false)])
                (match (intern-id-render (intern-id-provenance-capture) a-only)
                  [(InternIdRender.InvalidId) unit]
                  [_ (set! ok false)])
                (compiler-driver-state-install-interns! state-b)
                (unless
                  (compiler-driver-state-smoke-render-ok?
                    b-owner
                    b-shared
                    "sssssssssssssssssssssssssssssssssssssssssssssssss")
                  (set! ok false))
                ok))))))))

(define (compiler-driver-state-smoke-reset-does-not-install?) : bool
  (let
    [prior-pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [pools-b : AstNodePoolContext (compiler-driver-state-pool-context state-b)]
    [expr-id : i64
      (ast-node-pool-context-expr-push
        pools-b
        (AstExpr.Literal (ast-lit-int 4705)))]
    [type-id : i64 (ast-node-pool-context-type-push pools-b (AstType.I64))]
    (begin
      (compiler-driver-state-install-pools! state-b)
      (compiler-driver-state-install-interns! state-b)
      (intern-reset!)
      (let
        [name-id : i64 (intern "state-b-reset-decoy")]
        [owner : InternIdProvenance (intern-id-provenance-capture)]
        [generation : i64 (intern-generation)]
        [pool-address : i64 (intern-active-pool-data-addr)]
        (let
          [ok : bool
            (begin
              (compiler-driver-state-capture-active-interns! state-b)
              (compiler-driver-state-reset-file-state! state-a)
              (compiler-driver-state-release-file-state! state-a)
              (and
                (= (intern-generation) generation)
                (= (intern-active-pool-data-addr) pool-address)
                (compiler-driver-state-smoke-render-ok?
                  owner
                  name-id
                  "state-b-reset-decoy")
                (compiler-driver-state-smoke-global-expr-int? expr-id 4705)
                (compiler-driver-state-smoke-global-type-i64? type-id)))]
          (begin
            (ast-node-pool-context-install! prior-pools)
            ok))))))

(define (compiler-driver-state-smoke-target-cfgs-do-not-install?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    (begin
      (compiler-driver-state-install-interns! state-b)
      (intern-reset!)
      (let
        [decoy-id : i64 (intern "state-b-cfg-decoy")]
        [owner : InternIdProvenance (intern-id-provenance-capture)]
        [generation : i64 (intern-generation)]
        [pool-address : i64 (intern-active-pool-data-addr)]
        (begin
          (compiler-driver-state-capture-active-interns! state-b)
          (let
            [intern-state : InternCompatState
              (array-ref (struct-get state-a intern-state) 0)]
            [_persistent : unit
              (intern-compat-state-persistent-storage-enable! intern-state)]
            [qualified-id : i64
              (with-scratch
                (intern-compat-state-intern
                  intern-state
                  (string.substring "pkg/name.part-extra" 0 13)))]
            [cfgs : sym_i64_env.SymI64Env
              (compiler-driver-state-target-cfgs
                state-a
                (CompilerBackendTarget.Linux)
                (compiler-cfg-empty))]
            (and
              (= (intern-generation) generation)
              (= (intern-active-pool-data-addr) pool-address)
              (compiler-driver-state-smoke-render-ok?
                owner
                decoy-id
                "state-b-cfg-decoy")
              (intern-compat-state-qualified? intern-state qualified-id)
              (= (intern-compat-state-first-dot intern-state qualified-id) 8)
              (intern-private-string-eq
                (intern-compat-state-str
                  intern-state
                  (intern-compat-state-leading-dot-id intern-state qualified-id))
                "pkg/name")
              (intern-private-string-eq
                (intern-compat-state-str
                  intern-state
                  (intern-compat-state-qualified-module-id
                    intern-state
                    qualified-id))
                "pkg")
              (intern-private-string-eq
                (intern-compat-state-str
                  intern-state
                  (intern-compat-state-qualified-base-id
                    intern-state
                    qualified-id))
                "name.part")
              (sym_i64_env.sym-i64-contains-with-intern-state
                cfgs
                "cfg:linux"
                intern-state)
              (sym_i64_env.sym-i64-contains-with-intern-state
                cfgs
                "cfg:feature-cleanup-owner-reflection"
                intern-state))))))))

(define (compiler-driver-state-smoke-intern-arena-reset-isolated?) : bool
  (let
    ;; A nonzero ownership marker is sufficient for this focused helper: the
    ;; test calls only the intern-arena reset and never releases pool storage.
    [state-a : CompilerDriverState
      (compiler-driver-state-new-from-pools-and-arena
        (ast-expr-node-pool-state-create 1)
        (ast-type-node-pool-state-create 1)
        -1)]
    [state-b : CompilerDriverState
      (compiler-driver-state-new-from-pools-and-arena
        (ast-expr-node-pool-state-create 1)
        (ast-type-node-pool-state-create 1)
        -1)]
    [a-before : i64 (compiler-driver-state-intern-persistent-arena state-a)]
    [b-before : i64 (compiler-driver-state-intern-persistent-arena state-b)]
    (begin
      (compiler-driver-state-install-interns! state-b)
      (let
        [active-before : i64 (intern-persistent-arena-handle)]
        (begin
          (compiler-driver-state-reset-owned-intern-arena-if-uncached! state-a)
          (let
            [a-after : i64
              (compiler-driver-state-intern-persistent-arena state-a)]
            [b-after : i64
              (compiler-driver-state-intern-persistent-arena state-b)]
            [active-after : i64 (intern-persistent-arena-handle)]
            (and
              (not (= a-before a-after))
              (= b-before b-after)
              (= active-before b-before)
              (= active-after b-before))))))))

(define (compiler-driver-state-smoke-intern-table-reset-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    (begin
      (compiler-driver-state-install-interns! state-a)
      (intern-reset!)
      (intern "state-a-table")
      (compiler-driver-state-capture-active-interns! state-a)
      (compiler-driver-state-install-interns! state-b)
      (intern-reset!)
      (let
        [b-id : i64 (intern "state-b-table")]
        (begin
          (compiler-driver-state-capture-active-interns! state-b)
          (compiler-driver-state-apply-session-flags! state-b)
          (let
            [a-generation : i64
              (compiler-driver-state-intern-generation state-a)]
            [b-generation : i64
              (compiler-driver-state-intern-generation state-b)]
            (begin
              (compiler-load-session-reset-interns-with-state!
                (array-ref (struct-get state-a intern-state) 0))
              (and
                (= (compiler-driver-state-intern-pool-len state-a) 0)
                (=
                  (compiler-driver-state-intern-generation state-a)
                  (+ a-generation 1))
                (= (compiler-driver-state-intern-pool-len state-b) 1)
                (=
                  (compiler-driver-state-intern-generation state-b)
                  b-generation)
                (= (intern-pool-len) 1)
                (match (intern-lookup "state-b-table")
                  [(InternLookupFound found) (= found b-id)]
                  [(InternLookupMissing) false])))))))))

(define (compiler-driver-state-smoke-intern-storage-flags-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    (begin
      (compiler-driver-state-install-interns! state-b)
      (intern-persistent-storage-enable!)
      (compiler-driver-state-capture-active-interns! state-b)
      (compiler-driver-state-apply-session-flags! state-a)
      (compiler-driver-state-session-program-cache-disable state-a)
      (let
        [ok : bool
          (and
            (intern-persistent-storage-on?)
            (not
              (intern-compat-state-persistent-storage-enabled?
                (array-ref (struct-get state-a intern-state) 0)))
            (intern-compat-state-persistent-storage-enabled?
              (array-ref (struct-get state-b intern-state) 0)))]
        (begin
          (intern-persistent-storage-disable!)
          ok)))))

(define (compiler-driver-state-smoke-adopt-pools-does-not-install?) : bool
  (let
    [state : CompilerDriverState (compiler-driver-state-new)]
    [state-pools : AstNodePoolContext
      (ast-node-pool-context-new
        (compiler-driver-state-smoke-expr-push
          (ast-expr-node-pool-state-create 1)
          111)
        (ast-type-node-pool-state-create 1))]
    [active-pools : AstNodePoolContext
      (ast-node-pool-context-new
        (compiler-driver-state-smoke-expr-push
          (ast-expr-node-pool-state-create 1)
          222)
        (ast-type-node-pool-state-create 1))]
    (begin
      (ast-node-pool-context-install! active-pools)
      (compiler-driver-state-adopt-pools! state state-pools)
      (and
        (compiler-driver-state-smoke-expr-int?
          (array-ref
            (struct-get (compiler-driver-state-pool-context state) expr-pool)
            0)
          0
          111)
        (compiler-driver-state-smoke-expr-int?
          (ast-node-pool-state-capture)
          0
          222)))))

;; Parser dispatch ids are process-global cached data, while driver states own
;; distinct intern tables whose generation counters can have the same value.
;; Pre-interning one syntax name gives the two tables different ids without
;; changing the complete dispatch's marker id, reproducing the batch compiler
;; state switch that used to classify `never` with the previous table's index.
(define (compiler-driver-state-smoke-parser-dispatch-cache-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    (begin
      (compiler-driver-state-install-interns! state-a)
      (intern-reset!)
      (intern "never")
      (let
        [dispatch-a : sym_i64_env.SymI64Env (compiler-parse-dispatch-env)]
        [a-ok : bool
          (=
            (compiler-parse-dispatch-tag dispatch-a "never")
            (compiler-parse-tag-ty-never))]
        (begin
          (compiler-driver-state-install-interns! state-b)
          (intern-reset!)
          (let
            [dispatch-b : sym_i64_env.SymI64Env (compiler-parse-dispatch-env)]
            (and
              a-ok
              (=
                (compiler-parse-dispatch-tag dispatch-b "never")
                (compiler-parse-tag-ty-never)))))))))

(define (compiler-driver-state-smoke-lower-arenas-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [ok : bool true]
    (begin
      (compiler-driver-state-install-lower-arenas! state-a)
      (let
        [scratch-a : i64 (lower-scratch-arena-get)]
        [ir-a : i64 (lower-ir-arena-get)]
        (begin
          (compiler-driver-state-capture-active-lower-arenas! state-a)
          (compiler-driver-state-install-lower-arenas! state-b)
          (let
            [scratch-b : i64 (lower-scratch-arena-get)]
            [ir-b : i64 (lower-ir-arena-get)]
            (begin
              (compiler-driver-state-capture-active-lower-arenas! state-b)
              (compiler-driver-state-reset-file-state! state-b)
              (let
                [lower-b : CompilerLowerArenaState
                  (array-ref (struct-get state-b lower-arenas) 0)]
                [lower-a : CompilerLowerArenaState
                  (array-ref (struct-get state-a lower-arenas) 0)]
                (begin
                  (unless
                    (= (compiler-lower-arena-state-scratch-arena lower-b) 0)
                    (set! ok false))
                  (unless
                    (= (compiler-lower-arena-state-ir-arena lower-b) 0)
                    (set! ok false))
                  (unless
                    (=
                      (compiler-lower-arena-state-scratch-arena lower-a)
                      scratch-a)
                    (set! ok false))
                  (unless
                    (= (compiler-lower-arena-state-ir-arena lower-a) ir-a)
                    (set! ok false))
                  (compiler-driver-state-install-lower-arenas! state-a)
                  (unless
                    (= (lower-scratch-arena-get) scratch-a)
                    (set! ok false))
                  (unless (= (lower-ir-arena-get) ir-a) (set! ok false))
                  (unless (>= scratch-b 0) (set! ok false))
                  (unless (>= ir-b 0) (set! ok false))
                  (compiler-driver-state-reset-file-state! state-a)
                  ok)))))))))

(define (compiler-driver-state-smoke-lower-type-reads-use-context?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [program : AstProgram (ast-program (ast-decl-list-new))]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        [ref-ty : AstType (ast-ty-ref-with-pools pools-a "r" (AstType.Str))]
        [decoy-id : i64 (ast-node-pool-context-type-push pools-b (AstType.I64))]
        [array-ty : AstType
          (ast-ty-dyn-array-with-pools pools-a (AstType.Bool))]
        [array-decoy-id : i64
          (ast-node-pool-context-type-push pools-b (AstType.F64))]
        (match ref-ty
          [(AstType.Ref _ inner)
            (match (build-compiler-symbols program)
              [(ResultCompilerSymbols.Ok symbols)
                (match (build-compiler-registries-with-symbols program symbols)
                  [(ResultCompilerRegistries.Ok registries)
                    (let
                      [ctx : TcContext
                        (TcContext program symbols registries "" pools-a)]
                      [_ : unit (ast-node-pool-context-install! pools-b)]
                      [active-len : i64 (ty-node-pool-len)]
                      [name-id : i64 (intern "xs")]
                      [env : sym_i64_env.SymI64Env
                        (sym_i64_env.sym-i64-bind-id
                          (sym_i64_env.sym-i64-empty)
                          name-id
                          7)]
                      [type-env : TcTypeEnv
                        (tc-bind-id TcTypeEnv.Nil name-id array-ty)]
                      [dynamic-ok : bool
                        (match (lower-dynamic-array-var
                          ctx
                          env
                          type-env
                          (AstExpr.Var name-id))
                          [(LowerMaybeArrayVar.Some var-id elem-ty)
                            (and
                              (= var-id 7)
                              (tc-type-eq elem-ty (AstType.Bool)))]
                          [(LowerMaybeArrayVar.No) false])]
                      (and
                        (= inner decoy-id)
                        (= array-decoy-id (+ decoy-id 1))
                        (= active-len (ast-node-pool-context-type-len pools-b))
                        (lower-str-ref-type? ctx ref-ty)
                        (not (lower-bytes-ref-type? ctx ref-ty))
                        dynamic-ok
                        (= active-len (ty-node-pool-len))))]
                  [(ResultCompilerRegistries.Err _) false])]
              [(ResultCompilerSymbols.Err _) false])]
          [_ false])))))

(define (compiler-driver-state-smoke-lower-expr-reads-use-context?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [program : AstProgram (ast-program (ast-decl-list-new))]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        [cond-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (AstLiteral.Bool true)))]
        [then-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 7)))]
        [else-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 11)))]
        [arg0-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 3)))]
        [arg1-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 5)))]
        [cond-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 70)))]
        [then-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 700)))]
        [else-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 1100)))]
        [arg0-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 3000)))]
        [arg1-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 5000)))]
        [args-a : AstExprList
          (let
            [items : AstExprList (ast-expr-list-new)]
            (begin
              (ast-expr-list-push (&mut items) arg0-a)
              (ast-expr-list-push (&mut items) arg1-a)
              items))]
        [result-exprs-a : AstExprList
          (let
            [items : AstExprList (ast-expr-list-new)]
            (begin
              (ast-expr-list-push (&mut items) arg0-a)
              (ast-expr-list-push (&mut items) cond-a)
              items))]
        (match (build-compiler-symbols program)
          [(ResultCompilerSymbols.Ok symbols)
            (match (build-compiler-registries-with-symbols program symbols)
              [(ResultCompilerRegistries.Ok registries)
                (let
                  [ctx : TcContext
                    (TcContext program symbols registries "" pools-a)]
                  [lower-state : LowerState
                    (LowerState.State
                      0
                      0
                      0
                      "entry"
                      (compiler-ir-instr-builder-new)
                      (compiler-ir-block-builder-new)
                      (compiler-ir-function-builder-new)
                      "main"
                      (box (compiler-source-spans-empty))
                      (lower-empty-global-name-cache)
                      (lower-type-cache-from-env (TcTypeEnv.Nil))
                      (CompilerLowerMode.Scalar)
                      (lower_i64_i64_map.with-capacity 8)
                      0
                      0)]
                  [_ : unit (ast-node-pool-context-install! pools-b)]
                  [active-before : i64 (ast-node-pool-len)]
                  [lowered : ResultLowerExpr
                    (lower-expr
                      ctx
                      lower-state
                      (sym_i64_env.sym-i64-empty)
                      (TcTypeEnv.Nil)
                      (AstExpr.If cond-a then-a else-a))]
                  [args-lowered : ResultLowerArgs
                    (lower-args
                      ctx
                      lower-state
                      (sym_i64_env.sym-i64-empty)
                      (TcTypeEnv.Nil)
                      args-a)]
                  [result-type : ResultTcType
                    (lower-expr-list-result-type-fast
                      ctx
                      (sym_i64_env.sym-i64-empty)
                      (TcTypeEnv.Nil)
                      (lower-type-cache-from-env (TcTypeEnv.Nil))
                      result-exprs-a)]
                  [active-after : i64 (ast-node-pool-len)]
                  (and
                    (= cond-a cond-b)
                    (= then-a then-b)
                    (= else-a else-b)
                    (= arg0-a arg0-b)
                    (= arg1-a arg1-b)
                    (= active-before (ast-node-pool-context-expr-len pools-b))
                    (= active-after active-before)
                    (match lowered
                      [(ResultLowerExpr.Ok _) true]
                      [(ResultLowerExpr.Err _) false])
                    (match args-lowered
                      [(ResultLowerArgs.Ok arg-state _)
                        (compiler-driver-state-smoke-lower-args-from-state-a?
                          arg-state)]
                      [(ResultLowerArgs.Err _) false])
                    (match result-type
                      [(ResultTcType.Ok ty) (tc-type-eq ty (AstType.Bool))]
                      [(ResultTcType.Err _) false])))]
              [(ResultCompilerRegistries.Err _) false])]
          [(ResultCompilerSymbols.Err _) false])))))

(define (compiler-driver-state-smoke-lower-rvo-reads-use-context?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [program : AstProgram (ast-program (ast-decl-list-new))]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        [rvo-cond-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (AstLiteral.Bool true)))]
        [rvo-cond-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 72)))]
        [rvo-value-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 7)))]
        [rvo-value-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 73)))]
        [rvo-return-a : i64 (ast-expr-return-with-pools pools-a rvo-value-a)]
        [rvo-return-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 74)))]
        [rvo-else-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 0)))]
        [rvo-else-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 75)))]
        (match (build-compiler-symbols program)
          [(ResultCompilerSymbols.Ok symbols)
            (match (build-compiler-registries-with-symbols program symbols)
              [(ResultCompilerRegistries.Ok registries)
                (let
                  [ctx : TcContext
                    (TcContext program symbols registries "" pools-a)]
                  [_ : unit (ast-node-pool-context-install! pools-b)]
                  [active-before : i64 (ast-node-pool-len)]
                  [rvo-has-return : bool
                    (lower-rvo-expr-has-early-return?
                      ctx
                      (AstExpr.If rvo-cond-a rvo-return-a rvo-else-a))]
                  [active-after : i64 (ast-node-pool-len)]
                  (and
                    (= rvo-cond-a rvo-cond-b)
                    (= rvo-value-a rvo-value-b)
                    (= rvo-return-a rvo-return-b)
                    (= rvo-else-a rvo-else-b)
                    (= active-before (ast-node-pool-context-expr-len pools-b))
                    (= active-after active-before)
                    rvo-has-return))]
              [(ResultCompilerRegistries.Err _) false])]
          [(ResultCompilerSymbols.Err _) false])))))

(define (compiler-driver-state-smoke-lower-vector-analysis-uses-context?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [program : AstProgram (ast-program (ast-decl-list-new))]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        [array-name : i64 (intern "xs")]
        [index-name : i64 (intern "i")]
        [arr-a : i64
          (ast-node-pool-context-expr-push pools-a (AstExpr.Var array-name))]
        [arr-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 70)))]
        [idx-var-a : i64
          (ast-node-pool-context-expr-push pools-a (AstExpr.Var index-name))]
        [idx-var-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 71)))]
        [idx-span-a : i64
          (ast-expr-spanned-with-pools
            pools-a
            idx-var-a
            (ast-source-span 1 1 1 2))]
        [idx-span-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 72)))]
        [idx-offset-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 3)))]
        [_idx-offset-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 73)))]
        [idx-a : i64
          (ast-expr-binary-with-pools
            pools-a
            (AstBinOp.Add)
            idx-span-a
            idx-offset-a)]
        [idx-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 74)))]
        [array-ref-a : i64 (ast-expr-array-ref-with-pools pools-a arr-a idx-a)]
        [array-ref-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 75)))]
        [cond-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (AstLiteral.Bool true)))]
        [_cond-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 76)))]
        [else-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 0)))]
        [_else-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 77)))]
        [array-body-a : i64
          (ast-expr-if-with-pools pools-a cond-a array-ref-a else-a)]
        [array-body-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 78)))]
        [shuffle-a : i64 (ast-expr-spmd-shuffle-with-pools pools-a arr-a idx-a)]
        [_shuffle-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 79)))]
        [shuffle-body-a : i64
          (ast-expr-if-with-pools pools-a cond-a shuffle-a else-a)]
        [shuffle-body-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 80)))]
        [mul-left-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 2)))]
        [_mul-left-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 81)))]
        [mul-right-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 4)))]
        [_mul-right-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 82)))]
        [mul-a : i64
          (ast-expr-binary-with-pools
            pools-a
            (AstBinOp.Mul)
            mul-left-a
            mul-right-a)]
        [_mul-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 83)))]
        [add-left-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 1)))]
        [_add-left-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 84)))]
        [mul-body-a : i64
          (ast-expr-binary-with-pools pools-a (AstBinOp.Add) add-left-a mul-a)]
        [mul-body-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 85)))]
        [array-ty : AstType (ast-ty-dyn-array-with-pools pools-a (AstType.I32))]
        (match (build-compiler-symbols program)
          [(ResultCompilerSymbols.Ok symbols)
            (match (build-compiler-registries-with-symbols program symbols)
              [(ResultCompilerRegistries.Ok registries)
                (let
                  [ctx : TcContext
                    (TcContext program symbols registries "" pools-a)]
                  [env : sym_i64_env.SymI64Env
                    (sym_i64_env.sym-i64-bind-id
                      (sym_i64_env.sym-i64-empty)
                      array-name
                      99)]
                  [type-env : TcTypeEnv
                    (tc-bind-id TcTypeEnv.Nil array-name array-ty)]
                  [_ : unit (ast-node-pool-context-install! pools-b)]
                  [active-before : i64 (ast-node-pool-len)]
                  [array-body : AstExpr
                    (ast-node-pool-context-expr-get pools-a array-body-a)]
                  [shuffle-body : AstExpr
                    (ast-node-pool-context-expr-get pools-a shuffle-body-a)]
                  [mul-body : AstExpr
                    (ast-node-pool-context-expr-get pools-a mul-body-a)]
                  [array-ref : AstExpr (AstExpr.ArrayRef arr-a idx-span-a)]
                  [idx-expr : AstExpr
                    (ast-node-pool-context-expr-get pools-a idx-a)]
                  [active-after : i64 (ast-node-pool-len)]
                  (and
                    (= arr-a arr-b)
                    (= idx-var-a idx-var-b)
                    (= idx-span-a idx-span-b)
                    (= idx-a idx-b)
                    (= array-ref-a array-ref-b)
                    (= array-body-a array-body-b)
                    (= shuffle-body-a shuffle-body-b)
                    (= mul-body-a mul-body-b)
                    (= active-before (ast-node-pool-context-expr-len pools-b))
                    (= active-after active-before)
                    (lower-vector-body-has-array-read? ctx array-body)
                    (lower-vector-body-has-spmd-shuffle? ctx shuffle-body)
                    (lower-spmd-expr-has-mul? ctx mul-body)
                    (= (lower-masked-vector-index-offset ctx "i" idx-expr) 3)
                    (match (lower-array-ref-var-for-index
                      ctx
                      env
                      type-env
                      array-ref
                      "i")
                      [(LowerMaybeArrayVar.Some var-id elem-ty)
                        (and (= var-id 99) (tc-type-eq elem-ty (AstType.I32)))]
                      [(LowerMaybeArrayVar.No) false])))]
              [(ResultCompilerRegistries.Err _) false])]
          [(ResultCompilerSymbols.Err _) false])))))

(define (compiler-driver-state-smoke-lower-avx512-masked-uses-context?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [program : AstProgram (ast-program (ast-decl-list-new))]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        [inner-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (AstLiteral.Bool true)))]
        [inner-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 70)))]
        [spanned-a : i64
          (ast-expr-spanned-with-pools
            pools-a
            inner-a
            (ast-source-span 1 1 1 5))]
        [spanned-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 71)))]
        [exprs : AstExprList
          (let
            [items : AstExprList (ast-expr-list-new)]
            (begin
              (ast-expr-list-push (&mut items) spanned-a)
              items))]
        (match (build-compiler-symbols program)
          [(ResultCompilerSymbols.Ok symbols)
            (match (build-compiler-registries-with-symbols program symbols)
              [(ResultCompilerRegistries.Ok registries)
                (let
                  [ctx : TcContext
                    (TcContext program symbols registries "" pools-a)]
                  [lower-state : LowerState
                    (LowerState.State
                      0
                      0
                      0
                      "entry"
                      (compiler-ir-instr-builder-new)
                      (compiler-ir-block-builder-new)
                      (compiler-ir-function-builder-new)
                      "main"
                      (box (compiler-source-spans-empty))
                      (lower-empty-global-name-cache)
                      (lower-type-cache-from-env (TcTypeEnv.Nil))
                      (CompilerLowerMode.Avx512)
                      (lower_i64_i64_map.with-capacity 8)
                      0
                      0)]
                  [_ : unit (ast-node-pool-context-install! pools-b)]
                  [active-before : i64 (ast-node-pool-len)]
                  [lowered : ResultLowerExpr
                    (lower-avx512-masked-begin
                      ctx
                      lower-state
                      (sym_i64_env.sym-i64-empty)
                      (TcTypeEnv.Nil)
                      LowerStringSet.Nil
                      "i"
                      0
                      (CompilerIrValue.I64 255)
                      8
                      exprs)]
                  [active-after : i64 (ast-node-pool-len)]
                  (and
                    (= inner-a inner-b)
                    (= spanned-a spanned-b)
                    (= active-before (ast-node-pool-context-expr-len pools-b))
                    (= active-after active-before)
                    (match lowered
                      [(ResultLowerExpr.Ok result)
                        (match result
                          [(LowerExpr.Expr _ _ ty)
                            (tc-type-eq ty (AstType.Bool))])]
                      [(ResultLowerExpr.Err _) false])))]
              [(ResultCompilerRegistries.Err _) false])]
          [(ResultCompilerSymbols.Err _) false])))))

(define (compiler-driver-state-smoke-lower-spmd-inline-expr-pools?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [program : AstProgram (ast-program (ast-decl-list-new))]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        [left-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 7)))]
        [right-a : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (ast-lit-int 11)))]
        [left-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 70)))]
        [right-b : i64
          (ast-node-pool-context-expr-push
            pools-b
            (AstExpr.Literal (ast-lit-int 110)))]
        [before-a : i64 (ast-node-pool-context-expr-len pools-a)]
        [before-b : i64 (ast-node-pool-context-expr-len pools-b)]
        (match (build-compiler-symbols program)
          [(ResultCompilerSymbols.Ok symbols)
            (match (build-compiler-registries-with-symbols program symbols)
              [(ResultCompilerRegistries.Ok registries)
                (let
                  [ctx : TcContext
                    (TcContext program symbols registries "" pools-a)]
                  [_ : unit (ast-node-pool-context-install! pools-b)]
                  [active-before : i64 (ast-node-pool-len)]
                  [rewritten : ResultLowerAstExpr
                    (lower-spmd-inline-expr
                      ctx
                      (sym_i64_env.sym-i64-empty)
                      (TcTypeEnv.Nil)
                      (AstExpr.Binary (AstBinOp.Add) left-a right-a)
                      LowerSpmdInlineSubst.Nil
                      LowerStringSet.Nil)]
                  [after-a : i64 (ast-node-pool-context-expr-len pools-a)]
                  [active-after : i64 (ast-node-pool-len)]
                  (and
                    (= left-a left-b)
                    (= right-a right-b)
                    (= active-before before-b)
                    (= active-after before-b)
                    (> after-a before-a)
                    (match rewritten
                      [(ResultLowerAstExpr.Ok expr)
                        (match expr
                          [(AstExpr.Binary (AstBinOp.Add) left-id right-id)
                            (and
                              (>= left-id before-a)
                              (< left-id after-a)
                              (>= right-id before-a)
                              (< right-id after-a)
                              (compiler-driver-state-smoke-context-int-lit?
                                pools-a
                                left-id
                                7)
                              (compiler-driver-state-smoke-context-int-lit?
                                pools-a
                                right-id
                                11))]
                          [_ false])]
                      [(ResultLowerAstExpr.Err _) false])))]
              [(ResultCompilerRegistries.Err _) false])]
          [(ResultCompilerSymbols.Err _) false])))))

(define (compiler-driver-state-smoke-lower-clone-roots-source-a) : String
  "(defstruct CloneRootA (text String))
(define (use-clone [x : CloneRootA]) : CloneRootA (not-clone x))")

(define (compiler-driver-state-smoke-lower-clone-roots-source-b) : String
  "(defstruct CloneRootA (text String))
(define (use-clone [x : CloneRootA]) : CloneRootA (clone x))")

(define (compiler-driver-state-smoke-collect-clone-roots
  [ctx : TcContext]
  [_top-env : TcTypeEnv]
  [_names : LowerNameEnv]
  [program : AstProgram]) : CloneNameList
  (match program
    [(AstProgram.Program decls-box)
      (let
        [cursor : AstDeclList (box-get decls-box)]
        [done : bool false]
        (begin
          (tc-clone-root-collection-use! program)
          (while (not done)
            (match (ast-decl-list-step cursor)
              [(AstDeclListStep.Nil) (set! done true)]
              [(AstDeclListStep.Cons decl rest)
                (begin
                  (match (ast-decl-unwrapped decl)
                    [(AstDecl.DefFn name _ _ _ _)
                      (if (string.eq (intern-str name) "use-clone")
                        (begin
                          (tc-clone-root-collection-select-decl! decl "")
                          (set! done true))
                        unit)]
                    [_ unit])
                  (set! cursor rest))]))
          (tc-clone-root-collection-note!
            ctx
            (AstType.Struct (intern "CloneRootA")))
          (tc-clone-root-collection-finish! ctx)))]))

(define (compiler-driver-state-smoke-lower-reachability-source-a) : String
  "(define (helper) : i64 41)
(define (main) : i64 (helper))
(define (dead-a) : i64 0)")

(define (compiler-driver-state-smoke-lower-reachability-source-b) : String
  "(define (helper) : i64 100)
(define (main) : i64 (dead-a))
(define (dead-a) : i64 200)")

(define (compiler-driver-state-smoke-lower-reachability-uses-context?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        [paths : AstDeclPathList (ast-decl-path-list-new)]
        (match (parse-ast-source-diagnostic-with-cfg-and-pools
          "reach-state-a.tl"
          (compiler-driver-state-smoke-lower-reachability-source-a)
          (compiler-cfg-empty)
          pools-a)
          [(ResultAstProgramDiagnostic.Ok program-a)
            (match (parse-ast-source-diagnostic-with-cfg-and-pools
              "reach-state-b.tl"
              (compiler-driver-state-smoke-lower-reachability-source-b)
              (compiler-cfg-empty)
              pools-b)
              [(ResultAstProgramDiagnostic.Ok _)
                (let
                  [names : LowerNameEnv
                    (match program-a
                      [(AstProgram.Program decls-box)
                        (lower-name-env-from-decls
                          (box-get decls-box)
                          paths
                          "reach-state-a.tl"
                          LowerNameEnv.Nil)])]
                  [_ : unit (ast-node-pool-context-install! pools-b)]
                  [active-before : i64 (ast-node-pool-len)]
                  [pruned : LowerPrunedProgram
                    (lower-prune-unreachable-functions
                      pools-a
                      "reach-state-a.tl"
                      program-a
                      paths
                      names)]
                  [active-after : i64 (ast-node-pool-len)]
                  [ok : bool
                    (and
                      (= active-before (ast-node-pool-context-expr-len pools-b))
                      (= active-after active-before)
                      (match pruned
                        [(LowerPrunedProgram.Program kept-program _)
                          (match kept-program
                            [(AstProgram.Program kept-box)
                              (let
                                [kept : AstDeclList (box-get kept-box)]
                                (and
                                  (lower-test-decl-list-defines? kept "main")
                                  (lower-test-decl-list-defines? kept "helper")
                                  (not
                                    (lower-test-decl-list-defines?
                                      kept
                                      "dead-a"))))])]))]
                  (begin
                    (compiler-driver-state-reset-file-state! state-b)
                    ok))]
              [(ResultAstProgramDiagnostic.Err _) false])]
          [(ResultAstProgramDiagnostic.Err _) false])))))

(define (compiler-driver-state-smoke-lower-clone-roots-use-context?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (compiler-driver-state-reset-file-state! state-b)
      (compiler-driver-state-install-builtins! state-a)
      (let
        [pools-a : AstNodePoolContext
          (compiler-driver-state-pool-context state-a)]
        [pools-b : AstNodePoolContext
          (compiler-driver-state-pool-context state-b)]
        [paths : AstDeclPathList (ast-decl-path-list-new)]
        (match (parse-ast-source-diagnostic-with-cfg-and-pools
          "clone-state-a.tl"
          (compiler-driver-state-smoke-lower-clone-roots-source-a)
          (compiler-cfg-empty)
          pools-a)
          [(ResultAstProgramDiagnostic.Ok program-a)
            (match (parse-ast-source-diagnostic-with-cfg-and-pools
              "clone-state-b.tl"
              (compiler-driver-state-smoke-lower-clone-roots-source-b)
              (compiler-cfg-empty)
              pools-b)
              [(ResultAstProgramDiagnostic.Ok _)
                (match (build-compiler-symbols program-a)
                  [(ResultCompilerSymbols.Ok symbols)
                    (match (build-compiler-registries-with-symbols
                      program-a
                      symbols)
                      [(ResultCompilerRegistries.Ok registries)
                        (let
                          [ctx : TcContext
                            (TcContext program-a symbols registries "" pools-a)]
                          [names : LowerNameEnv
                            (match program-a
                              [(AstProgram.Program decls-box)
                                (lower-name-env-from-decls
                                  (box-get decls-box)
                                  paths
                                  "clone-state-a.tl"
                                  LowerNameEnv.Nil)])]
                          (match (tc-build-top-env ctx program-a)
                            [(ResultTcEnv.Ok top-env)
                              (let
                                [_ : unit
                                  (ast-node-pool-context-install! pools-b)]
                                [active-before : i64 (ast-node-pool-len)]
                                [roots : CloneNameList
                                  (compiler-driver-state-smoke-collect-clone-roots
                                    ctx
                                    top-env
                                    names
                                    program-a)]
                                [active-after : i64 (ast-node-pool-len)]
                                (and
                                  (=
                                    active-before
                                    (ast-node-pool-context-expr-len pools-b))
                                  (= active-after active-before)
                                  (match roots
                                    [(CloneNameList.Cons name rest)
                                      (and
                                        (string.eq name "CloneRootA")
                                        (match (box-get rest)
                                          [(CloneNameList.Nil) true]
                                          [_ false]))]
                                    [_ false])))]
                            [(ResultTcEnv.Err _) false]))]
                      [(ResultCompilerRegistries.Err _) false])]
                  [(ResultCompilerSymbols.Err _) false])]
              [(ResultAstProgramDiagnostic.Err _) false])]
          [(ResultAstProgramDiagnostic.Err _) false])))))

(define (compiler-driver-state-smoke-lowered-result-pools-survive-reset?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new-for-compile)]
    [state-b : CompilerDriverState (compiler-driver-state-new-for-compile)]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) "stdlib")
          items))]
    (begin
      (compiler-load-session-cache-disable-for-test!)
      (compiler-driver-state-reset-file-state! state-a)
      (let
        [lowered : ResultCompilerDriverLowered
          (compiler-driver-load-and-lower-escaping-with-state
            state-a
            "tests/integration/calc.tl"
            (CompilerBackendTarget.Linux)
            roots
            (CompilerBackendMode.Scalar)
            (compiler-driver-state-target-cfgs
              state-a
              (CompilerBackendTarget.Linux)
              (compiler-cfg-empty)))]
        (match lowered
          [(ResultCompilerDriverLowered.Ok _ _ pools-a)
            (let
              [pools-b : AstNodePoolContext
                (compiler-driver-state-pool-context state-b)]
              (begin
                (compiler-driver-state-reset-file-state! state-b)
                (ast-node-pool-context-type-push pools-b (AstType.Bool))
                (ast-node-pool-context-type-push pools-b (AstType.Char))
                (ast-node-pool-context-install! pools-b)
                (let
                  [active-type-len-before : i64 (ty-node-pool-len)]
                  [emitted : ResultCompilerDriver
                    (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
                      "tests/integration/calc.tl"
                      lowered
                      (CompilerBackendTarget.Linux)
                      true
                      (CompilerBackendMode.Scalar)
                      1
                      true
                      false)]
                  (and
                    (> (ast-node-pool-context-expr-len pools-a) 0)
                    (> (ast-node-pool-context-type-len pools-a) 0)
                    (= active-type-len-before 2)
                    (= (ty-node-pool-len) active-type-len-before)
                    (match emitted
                      [(ResultCompilerDriver.Ok asm)
                        (and
                          (compiler-backend-string-contains? asm "calc")
                          (compiler-backend-string-contains? asm "main"))]
                      [(ResultCompilerDriver.Err _) false])))))]
          [(ResultCompilerDriverLowered.Err _) false])))))

(define (compiler-driver-state-smoke-compile-entry
  [state : CompilerDriverState]
  [input-path : String]
  [stdlib-roots : svec.Vec]) : bool
  (let
    [decoy-state : CompilerDriverState (compiler-driver-state-new)]
    (begin
      (compiler-driver-state-reset-file-state! state)
      (compiler-driver-state-install-pools! decoy-state)
      (let
        [ok : bool
          (match (compiler-driver-load-and-lower-escaping-with-state
            state
            input-path
            (CompilerBackendTarget.Linux)
            stdlib-roots
            (CompilerBackendMode.Scalar)
            (compiler-driver-state-target-cfgs
              state
              (CompilerBackendTarget.Linux)
              (compiler-cfg-empty)))
            [(ResultCompilerDriverLowered.Ok _ _ _) true]
            [(ResultCompilerDriverLowered.Err _) false])]
        (begin
          (compiler-driver-state-capture-session-floors! state)
          ok)))))

(define (compiler-driver-state-smoke-checked-lower-adopts-dest-pools?) : bool
  (let
    [state : CompilerDriverState
      (compiler-driver-state-session-program-cache-disable
        (compiler-driver-state-new-for-compile))]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) "stdlib")
          items))]
    (begin
      (compiler-load-session-cache-disable-for-test!)
      (compiler-driver-state-reset-file-state! state)
      (let
        [source-arena : i64 (compiler-driver-state-owned-pool-arena state)]
        [lowered : ResultCompilerDriverLowered
          (compiler-driver-load-and-lower-escaping-with-state
            state
            "tests/integration/calc.tl"
            (CompilerBackendTarget.Linux)
            roots
            (CompilerBackendMode.Scalar)
            (compiler-driver-state-target-cfgs
              state
              (CompilerBackendTarget.Linux)
              (compiler-cfg-empty)))]
        [state-pools : AstNodePoolContext
          (compiler-driver-state-pool-context state)]
        [dest-arena : i64 (compiler-driver-state-owned-pool-arena state)]
        [ok : bool
          (match lowered
            [(ResultCompilerDriverLowered.Ok _ _ result-pools)
              (and
                (not (= source-arena 0))
                (not (= dest-arena 0))
                (not (= source-arena dest-arena))
                (= dest-arena (ast-node-pool-context-base-arena state-pools))
                (= dest-arena (ast-node-pool-context-base-arena result-pools))
                (> (ast-node-pool-context-expr-len result-pools) 0)
                (> (ast-node-pool-context-type-len result-pools) 0))]
            [(ResultCompilerDriverLowered.Err _) false])]
        (begin
          (compiler-driver-state-capture-session-floors! state)
          (compiler-load-session-cache-disable-for-test!)
          ok)))))

(define (compiler-driver-state-smoke-batch-prelude-cache-floors?) : bool
  (let
    [state : CompilerDriverState
      (compiler-driver-state-session-program-cache-disable
        (compiler-driver-state-session-cache-enable
          (compiler-driver-state-new-for-compile)))]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) "stdlib")
          items))]
    [ok : bool true]
    (begin
      (compiler-load-session-cache-disable-for-test!)
      (unless
        (compiler-driver-state-smoke-compile-entry
          state
          "tests/integration/calc.tl"
          roots)
        (set! ok false))
      (unless
        (compiler-driver-state-smoke-compile-entry
          state
          "tests/integration/lexer.tl"
          roots)
        (set! ok false))
      (compiler-load-session-cache-disable-for-test!)
      ok)))

(define (compiler-driver-state-smoke-scratch-batch-owned-pool?) : bool
  (let
    [state : CompilerDriverState
      (compiler-driver-state-session-program-cache-disable
        (compiler-driver-state-new-for-compile))]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) "stdlib")
          items))]
    [ok : bool true]
    (begin
      (compiler-load-session-cache-disable-for-test!)
      (unless
        (with-scratch
          (compiler-driver-state-smoke-compile-entry
            state
            "tests/integration/calc.tl"
            roots))
        (set! ok false))
      (unless
        (with-scratch
          (compiler-driver-state-smoke-compile-entry
            state
            "tests/integration/lexer.tl"
            roots))
        (set! ok false))
      (compiler-load-session-cache-disable-for-test!)
      ok)))

(define (compiler-driver-state-smoke-emitted-batch-path-restores-scratch?
  [input-path : String]) : bool
  (let
    [state : CompilerDriverState
      (compiler-driver-state-session-program-cache-disable
        (compiler-driver-state-new-for-compile))]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) "stdlib")
          items))]
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    [_set-scratch : unit
      (unsafe
        (arena.set! scratch))]
    [_reset-before : unit (compiler-driver-state-reset-file-state! state)]
    [emitted? : bool
      (match (compiler-driver-state-emit-file-buffer-with-target-roots-level-mode-and-cfg
        state
        input-path
        (CompilerBackendTarget.Linux)
        true
        roots
        1
        (CompilerBackendMode.Scalar)
        (compiler-cfg-empty))
        [(ResultCompilerDriverBuffer.Ok _) true]
        [(ResultCompilerDriverBuffer.Err _) false])]
    [scratch-end : arena.Arena (arena.current)]
    [restored? : bool (arena.eq? scratch-end scratch)]
    (unsafe
      (begin
        (arena.set! home)
        ;; Mirror compile-batch cleanup: retain only a one-slot compatibility
        ;; pool while entry-owned caches are detached, then destroy the caller
        ;; scratch chain. Full load capacity is prepared only for the next
        ;; entry, after the old chain is gone.
        (compiler-driver-state-release-file-state! state)
        (let
          [released-pools : AstNodePoolContext
            (compiler-driver-state-pool-context state)]
          (unless
            (and
              (= (ast-node-pool-context-expr-capacity released-pools) 1)
              (= (ast-node-pool-context-type-capacity released-pools) 1))
            (set! restored? false)))
        (arena.set! home)
        (arena.destroy scratch-end)
        (compiler-driver-state-reset-file-state! state)
        (let
          [next-pools : AstNodePoolContext
            (compiler-driver-state-pool-context state)]
          (and
            emitted?
            restored?
            (=
              (ast-node-pool-context-expr-capacity next-pools)
              compiler-driver-compile-load-expr-pool-initial-capacity)
            (=
              (ast-node-pool-context-type-capacity next-pools)
              compiler-driver-compile-type-pool-initial-capacity)))))))

(define (compiler-driver-state-smoke-emitted-batch-restores-scratch?) : bool
  (compiler-driver-state-smoke-emitted-batch-path-restores-scratch?
    "tests/integration/calc.tl"))

(define (compiler-driver-state-smoke-retired-dispatch-thunk?) : bool
  (compiler-driver-state-smoke-emitted-batch-path-restores-scratch?
    "tests/spmd/runtime_dispatch_select.tl"))

(define (compiler-driver-state-smoke-global-reset-detaches-scratch-active-context?) : bool
  (begin
    (compiler-driver-reset-file-state!)
    (with-scratch
      (let
        [prev : AstNodePoolContext (ast-node-pool-context-capture-active)]
        [temp : AstNodePoolContext
          (ast-node-pool-context-new-with-capacities 1 1)]
        (begin
          (ast-node-pool-context-install! temp)
          (ast-node-pool-context-install! prev)
          unit)))
    (compiler-driver-reset-file-state!)
    true))

(define (compiler-driver-state-smoke-emit-ir-core-macro-source) : String
  "(define (main) : i64
  (if (and true true)
    42
    1))")

(define (compiler-driver-state-smoke-emit-ir-core-macro-fixture-path) : String
  (let
    [path : String "target/compiler_driver_emit_ir_core_macro.tl"]
    [fallback : String "compiler_driver_emit_ir_core_macro.tl"]
    [source : String (compiler-driver-state-smoke-emit-ir-core-macro-source)]
    (match (io.try-write-file (& path) (& source))
      [(io.OkIoUnit) path]
      [(io.ErrIoUnit _)
        (begin
          (io.write-file fallback source)
          fallback)])))

(define (compiler-driver-state-smoke-emit-ir-core-macro-prelude?) : bool
  (let
    [state : CompilerDriverState (compiler-driver-state-new-for-compile)]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) "stdlib")
          items))]
    [input-path : String
      (compiler-driver-state-smoke-emit-ir-core-macro-fixture-path)]
    [needle : String "score"]
    (begin
      (compiler-driver-state-reset-file-state! state)
      (match (compiler-driver-state-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
        state
        input-path
        (CompilerBackendTarget.Linux)
        roots
        2
        (CompilerBackendMode.Scalar)
        (compiler-cfg-empty))
        [(ResultCompilerDriver.Ok summary)
          (and
            (> (string.string-length summary) 0)
            (string.contains (& summary) (& needle)))]
        [(ResultCompilerDriver.Err _) false]))))

(define (compiler-driver-state-smoke-double-lower-source) : String
  "(define (main) : i64 29)")

(define (compiler-driver-state-smoke-double-lower-fixture-path) : String
  (let
    [path : String "target/compiler_driver_double_lower_loaded.tl"]
    [fallback : String "compiler_driver_double_lower_loaded.tl"]
    [source : String (compiler-driver-state-smoke-double-lower-source)]
    (match (io.try-write-file (& path) (& source))
      [(io.OkIoUnit) path]
      [(io.ErrIoUnit _)
        (begin
          (io.write-file fallback source)
          fallback)])))

(define (compiler-driver-state-smoke-lower-loaded-with-pools
  [input-path : String]
  [roots : svec.Vec]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [pools : AstNodePoolContext]) : ResultCompilerLower
  (lower-compiler-program-with-decl-paths-mode-cache-and-pools
    input-path
    (ast-program decls)
    paths
    (CompilerLowerMode.Scalar)
    roots
    (tc-prefix-default-cache-scope)
    pools))

(define (compiler-driver-state-smoke-lower-expanded-loaded-with-pools
  [input-path : String]
  [roots : svec.Vec]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [pools : AstNodePoolContext]) : ResultCompilerLower
  (lower-compiler-expanded-program-with-decl-paths-mode-cache-and-pools
    input-path
    (ast-program decls)
    paths
    (CompilerLowerMode.Scalar)
    roots
    (tc-prefix-default-cache-scope)
    pools))

(define (compiler-driver-state-smoke-lower-loaded-twice-status) : i64
  (let
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) "stdlib")
          items))]
    [input-path : String
      (compiler-driver-state-smoke-double-lower-fixture-path)]
    (begin
      (compiler-driver-reset-file-state!)
      (match (compiler-driver-load-package-file-with-runtime
        input-path
        (CompilerBackendTarget.Linux)
        roots
        ""
        (compiler-pkg-deps-empty)
        true)
        [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (let
            [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
            [decoy-pools : AstNodePoolContext
              (ast-node-pool-context-new-with-capacities 2 2)]
            [_install-decoy-first : unit
              (ast-node-pool-context-install! decoy-pools)]
            (match (compiler-driver-state-smoke-lower-loaded-with-pools
              input-path
              roots
              decls
              paths
              pools)
              [(ResultCompilerLower.Ok _ _)
                (begin
                  (ast-node-pool-context-install! decoy-pools)
                  (match (compiler-driver-state-smoke-lower-expanded-loaded-with-pools
                    input-path
                    roots
                    decls
                    paths
                    pools)
                    [(ResultCompilerLower.Ok _ _)
                      (begin
                        (compiler-driver-reset-file-state!)
                        0)]
                    [(ResultCompilerLower.Err _)
                      (begin
                        (io.print-error
                          "double lower smoke: second lower failed")
                        (compiler-driver-reset-file-state!)
                        3)]))]
              [(ResultCompilerLower.Err diag)
                (begin
                  (io.print-error "double lower smoke: first lower failed")
                  (io.print-error (compiler-diagnostic-render (box-get diag)))
                  (compiler-driver-reset-file-state!)
                  2)]))]
        [(ResultCompilerLoadWithPaths.Err diag)
          (begin
            (io.print-error "double lower smoke: load failed")
            (io.print-error (compiler-diagnostic-render (box-get diag)))
            (compiler-driver-reset-file-state!)
            1)]))))

(define (main) : i64
  (begin
    (unless (compiler-driver-state-smoke-cache-isolated?) (return 2))
    (unless (compiler-driver-state-smoke-reset-flags-isolated?) (return 3))
    (unless
      (compiler-driver-state-smoke-load-session-storage-isolated?)
      (return 6))
    (unless (compiler-driver-state-smoke-pools-isolated?) (return 4))
    (unless (compiler-driver-state-smoke-type-dedup-isolated?) (return 5))
    (unless (compiler-driver-state-smoke-parse-pools-isolated?) (return 12))
    (unless (compiler-driver-state-smoke-clone-pools-isolated?) (return 14))
    (unless (compiler-driver-state-smoke-clone-augment-dest-pools?) (return 27))
    (unless
      (compiler-driver-state-smoke-specialize-pools-isolated?)
      (return 15))
    (unless (compiler-driver-state-smoke-active-pools-isolated?) (return 7))
    (unless (compiler-driver-state-smoke-ctfe-pools-isolated?) (return 15))
    (unless
      (compiler-driver-state-smoke-typecheck-macro-pools-isolated?)
      (return 16))
    (unless (compiler-driver-state-smoke-builtins-isolated?) (return 8))
    (unless
      (compiler-driver-state-smoke-builtins-scratch-capture-stable?)
      (return 10))
    (unless (compiler-driver-state-smoke-interns-isolated?) (return 29))
    (unless (compiler-driver-state-smoke-reset-does-not-install?) (return 36))
    (unless
      (compiler-driver-state-smoke-target-cfgs-do-not-install?)
      (return 37))
    (unless
      (compiler-driver-state-smoke-intern-arena-reset-isolated?)
      (return 32))
    (unless
      (compiler-driver-state-smoke-intern-table-reset-isolated?)
      (return 33))
    (unless
      (compiler-driver-state-smoke-intern-storage-flags-isolated?)
      (return 35))
    (unless
      (compiler-driver-state-smoke-adopt-pools-does-not-install?)
      (return 34))
    (unless
      (compiler-driver-state-smoke-parser-dispatch-cache-isolated?)
      (return 31))
    (unless (compiler-driver-state-smoke-lower-arenas-isolated?) (return 9))
    (unless
      (compiler-driver-state-smoke-lower-type-reads-use-context?)
      (return 18))
    (unless
      (compiler-driver-state-smoke-lower-expr-reads-use-context?)
      (return 22))
    (unless
      (compiler-driver-state-smoke-lower-rvo-reads-use-context?)
      (return 24))
    (unless
      (compiler-driver-state-smoke-lower-vector-analysis-uses-context?)
      (return 23))
    (unless
      (compiler-driver-state-smoke-lower-avx512-masked-uses-context?)
      (return 25))
    (unless
      (compiler-driver-state-smoke-lower-spmd-inline-expr-pools?)
      (return 19))
    (unless
      (compiler-driver-state-smoke-lower-clone-roots-use-context?)
      (return 20))
    (unless
      (compiler-driver-state-smoke-lower-reachability-uses-context?)
      (return 21))
    (unless
      (compiler-driver-state-smoke-lowered-result-pools-survive-reset?)
      (return 11))
    (unless
      (compiler-driver-state-smoke-checked-lower-adopts-dest-pools?)
      (return 28))
    (unless
      (compiler-driver-state-smoke-batch-prelude-cache-floors?)
      (return 13))
    (unless (compiler-driver-state-smoke-scratch-batch-owned-pool?) (return 25))
    (unless
      (compiler-driver-state-smoke-emitted-batch-restores-scratch?)
      (return 32))
    (unless (compiler-driver-state-smoke-retired-dispatch-thunk?) (return 33))
    (unless
      (compiler-driver-state-smoke-global-reset-detaches-scratch-active-context?)
      (return 26))
    (unless
      (compiler-driver-state-smoke-emit-ir-core-macro-prelude?)
      (return 17))
    (let
      [double-lower-status : i64
        (compiler-driver-state-smoke-lower-loaded-twice-status)]
      (unless (= double-lower-status 0) (return (+ 260 double-lower-status))))
    42))