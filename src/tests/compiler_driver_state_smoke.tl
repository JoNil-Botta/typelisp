(import stdlib.string)
(import stdlib.io)
(import stdlib.vector)
(import "../compiler_driver_core.tl")
(import "../compiler_lower.tl")
(import "../compiler_clone.tl")
(import "../compiler_specialize.tl")
(import "../compiler_ctfe.tl")
(import sym_i64_env)

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
        [(AstLitInt value _) (= value expected)]
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
        [(AstLitInt value _) (= value expected)]
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
    [program : AstProgram (ast-program AstDeclList.Nil)]
    [ok : bool true]
    (begin
      (compiler-driver-state-apply-session-flags! state-a)
      (compiler-load-program-cache-clear!)
      (unless
        (compiler-load-program-cache-store "state-key" program)
        (set! ok false))
      (compiler-load-runtime-prelude-cache-store
        "prelude-key"
        AstDeclList.Nil
        AstDeclPathList.Nil
        AstDeclModuleList.Nil
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
    [(AstExpr.Literal (AstLitBool value)) (= value want)]
    [_ false]))

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
      (match (box-get decls-box)
        [(AstDeclList.Cons
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
        (ast-field-def-cons field AstFieldDefList.Nil))]
    (ast-program (ast-decl-cons decl AstDeclList.Nil))))

(define (compiler-driver-state-smoke-clone-generated-ctor?
  [pools : AstNodePoolContext]
  [program : AstProgram]
  [name : String]) : bool
  (match program
    [(AstProgram.Program decls-box)
      (match (box-get decls-box)
        [(AstDeclList.Cons _ rest)
          (match (box-get rest)
            [(AstDeclList.Cons decl tail)
              (match (box-get tail)
                [(AstDeclList.Nil)
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
        [(AstBinAdd)
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
                      [(AstLitInt value _) (= value 7)]
                      [_ false])]
                  [_ false])
                false)]
            [_ false])]
        [_ false])]
    [_ false]))

(define (compiler-driver-state-smoke-specialized-scale-decls-ok?
  [pools : AstNodePoolContext]
  [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclList.Nil) false]
    [(AstDeclList.Cons decl rest)
      (match decl
        [(AstDecl.DefFn name _ _ body _)
          (if (string.eq (intern-str name) "__tl_specialized_scale_i64_7_none")
            (compiler-driver-state-smoke-specialized-scale-body-ok? pools body)
            (compiler-driver-state-smoke-specialized-scale-decls-ok?
              pools
              (box-get rest)))]
        [_
          (compiler-driver-state-smoke-specialized-scale-decls-ok?
            pools
            (box-get rest))])]))

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
            (AstExpr.Literal (AstLitBool true)))]
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
            (AstExpr.Literal (AstLitBool true)))]
        [quote-false-id : i64
          (ast-node-pool-context-expr-push
            pools-a
            (AstExpr.Literal (AstLitBool false)))]
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
            AstDeclPathList.Nil
            (vector.string-vec-new)
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
    [ok : bool true]
    (begin
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
                    (=
                      (compiler-driver-state-builtin-generation state-a)
                      state-a-generation)
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
              (compiler-driver-builtin-reset!)
              (compiler-driver-state-install-builtins! state)
              (unless
                (compiler-driver-builtin-typecheck-string-length-id?
                  string-length-id)
                (set! ok false))
              ok)))))))

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
    [program : AstProgram (ast-program AstDeclList.Nil)]
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
                      (and
                        (= inner decoy-id)
                        (= active-len (ast-node-pool-context-type-len pools-b))
                        (lower-str-ref-type? ctx ref-ty)
                        (not (lower-bytes-ref-type? ctx ref-ty))
                        (= active-len (ty-node-pool-len))))]
                  [(ResultCompilerRegistries.Err _) false])]
              [(ResultCompilerSymbols.Err _) false])]
          [_ false])))))

(define (compiler-driver-state-smoke-lowered-result-pools-survive-reset?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new-for-compile)]
    [state-b : CompilerDriverState (compiler-driver-state-new-for-compile)]
    [roots : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) "stdlib")]
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
            (compiler-driver-target-cfgs
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
  [stdlib-roots : vector.StringVec]) : bool
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
            (compiler-driver-target-cfgs
              (CompilerBackendTarget.Linux)
              (compiler-cfg-empty)))
            [(ResultCompilerDriverLowered.Ok _ _ _) true]
            [(ResultCompilerDriverLowered.Err _) false])]
        (begin
          (compiler-driver-state-capture-session-floors! state)
          ok)))))

(define (compiler-driver-state-smoke-batch-prelude-cache-floors?) : bool
  (let
    [state : CompilerDriverState
      (compiler-driver-state-session-program-cache-disable
        (compiler-driver-state-session-cache-enable
          (compiler-driver-state-new-for-compile)))]
    [roots : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) "stdlib")]
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
    [roots : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) "stdlib")]
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
    (unless (compiler-driver-state-smoke-lower-arenas-isolated?) (return 9))
    (unless
      (compiler-driver-state-smoke-lower-type-reads-use-context?)
      (return 18))
    (unless
      (compiler-driver-state-smoke-lowered-result-pools-survive-reset?)
      (return 11))
    (unless
      (compiler-driver-state-smoke-batch-prelude-cache-floors?)
      (return 13))
    (unless
      (compiler-driver-state-smoke-emit-ir-core-macro-prelude?)
      (return 17))
    42))
