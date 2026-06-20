(import "../compiler_driver_core.tl")

(define (compiler-driver-state-smoke-expr-push
  [pool : AstExprNodePoolState]
  [value : i64]) : AstExprNodePoolState
  (match (ast-expr-node-pool-state-push
    pool
    (AstExprLiteral (ast-lit-int value)))
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
        [(AstLitInt value _) (= value expected)]
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

(define (compiler-driver-state-smoke-global-expr-int?
  [id : i64]
  [expected : i64]) : bool
  (match (ast-node-get id)
    [(AstExprLiteral lit)
      (match lit
        [(AstLitInt value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-driver-state-smoke-global-type-i64? [id : i64]) : bool
  (match (ty-node-get id)
    [(AstTyI64) true]
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
    [program : AstProgram (ast-program AstDeclNil)]
    [ok : bool true]
    (begin
      (compiler-driver-state-apply-session-flags! state-a)
      (compiler-load-program-cache-clear!)
      (unless
        (compiler-load-program-cache-store "state-key" program)
        (set! ok false))
      (compiler-load-runtime-prelude-cache-store
        "prelude-key"
        AstDeclNil
        AstDeclPathNil
        AstDeclModuleNil
        (sym-i64-empty))
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
      (compiler-driver-state-smoke-type-push type-a0 (AstTyI64))]
    [type-a-id1 : i64 (ast-type-node-pool-state-mark type-a1)]
    [type-a2 : AstTypeNodePoolState
      (compiler-driver-state-smoke-type-push type-a1 (AstTyString))]
    [type-b0 : AstTypeNodePoolState
      (array-ref (struct-get state-b type-pool) 0)]
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

(define (compiler-driver-state-smoke-type-dedup-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [type-a0 : AstTypeNodePoolState
      (array-ref (struct-get state-a type-pool) 0)]
    [type-b0 : AstTypeNodePoolState
      (array-ref (struct-get state-b type-pool) 0)]
    (match (ast-type-node-pool-state-push type-a0 (AstTyI64))
      [(AstTypeNodePoolPushOk type-a1 a-id)
        (match (ast-type-node-pool-state-push type-b0 (AstTyI64))
          [(AstTypeNodePoolPushOk type-b1 b-id)
            (match (ast-type-node-pool-state-push type-a1 (AstTyI64))
              [(AstTypeNodePoolPushOk type-a2 a-dupe-id)
                (match (ast-type-node-pool-state-push type-b1 (AstTyI64))
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

(define (compiler-driver-state-smoke-active-pools-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [ok : bool true]
    (begin
      (compiler-driver-state-install-pools! state-a)
      (let
        [expr-a-id : i64 (ast-node-push (AstExprLiteral (ast-lit-int 7)))]
        [type-a-id : i64 (ty-node-push (AstTyI64))]
        (begin
          (compiler-driver-state-capture-active-pools! state-a)
          (compiler-driver-state-install-pools! state-b)
          (let
            [expr-b-id : i64 (ast-node-push (AstExprLiteral (ast-lit-int 11)))]
            [type-b-id : i64 (ty-node-push (AstTyChar))]
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

(define (compiler-driver-state-smoke-builtins-isolated?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    [ok : bool true]
    (begin
      (compiler-driver-state-install-builtins! state-a)
      (let
        [string-length-id : i64 (intern "string-length")]
        (begin
          (unless
            (compiler-builtin-typecheck-string-length-id? string-length-id)
            (set! ok false))
          (compiler-driver-state-capture-active-builtins! state-a)
          (let
            [state-a-generation : i64
              (compiler-builtin-ids-state-generation
                (array-ref (struct-get state-a builtin-ids) 0))]
            (begin
              (compiler-driver-state-install-builtins! state-b)
              (let
                [array-length-id : i64 (intern "array-length")]
                (begin
                  (unless
                    (compiler-builtin-typecheck-array-length-id?
                      array-length-id)
                    (set! ok false))
                  (compiler-driver-state-capture-active-builtins! state-b)
                  (compiler-driver-state-reset-file-state! state-b)
                  (unless
                    (=
                      (compiler-builtin-ids-state-generation
                        (array-ref (struct-get state-a builtin-ids) 0))
                      state-a-generation)
                    (set! ok false))
                  (compiler-driver-state-install-builtins! state-a)
                  (let
                    [string-length-id-after-reset : i64
                      (intern "string-length")]
                    (begin
                      (unless
                        (compiler-builtin-typecheck-string-length-id?
                          string-length-id-after-reset)
                        (set! ok false))
                      ok)))))))))))

(define (compiler-driver-state-smoke-builtin-ids-data-addr
  [state : CompilerBuiltinIdsState]) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (array-data (struct-get state ids)) : (Ptr u8))))
    : i64))

(define (compiler-driver-state-smoke-builtins-scratch-capture-stable?) : bool
  (let
    [state : CompilerDriverState (compiler-driver-state-new)]
    [ok : bool true]
    (begin
      (compiler-driver-state-install-builtins! state)
      (let
        [before : i64
          (compiler-driver-state-smoke-builtin-ids-data-addr
            (array-ref (struct-get state builtin-ids) 0))]
        [string-length-id : i64 (intern "string-length")]
        (begin
          (unless
            (compiler-builtin-typecheck-string-length-id? string-length-id)
            (set! ok false))
          (with-scratch (compiler-driver-state-capture-active-builtins! state))
          (let
            [after : i64
              (compiler-driver-state-smoke-builtin-ids-data-addr
                (array-ref (struct-get state builtin-ids) 0))]
            (begin
              (unless (= before after) (set! ok false))
              (compiler-builtin-reset!)
              (compiler-driver-state-install-builtins! state)
              (unless
                (compiler-builtin-typecheck-string-length-id? string-length-id)
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

(define (compiler-driver-state-smoke-lowered-result-pools-survive-reset?) : bool
  (let
    [state-a : CompilerDriverState (compiler-driver-state-new)]
    [state-b : CompilerDriverState (compiler-driver-state-new)]
    (begin
      (compiler-driver-state-reset-file-state! state-a)
      (match (lower-compiler-source (compiler-lower-make-array-source))
        [(OkCompilerLower program spans)
          (let
            [lowered : ResultCompilerDriverLowered
              (compiler-driver-lowered-from-active-pools program spans)]
            (begin
              (compiler-driver-state-capture-session-floors! state-a)
              (compiler-driver-state-reset-file-state! state-b)
              (ty-node-push (AstTyBool))
              (ty-node-push (AstTyChar))
              (compiler-driver-state-capture-session-floors! state-b)
              (let
                [emitted-ok : bool
                  (match (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
                    "<state-smoke>"
                    lowered
                    (BackendTargetLinux)
                    true
                    (BackendModeScalar)
                    0
                    true
                    false)
                    [(OkCompilerDriver asm)
                      (and
                        (compiler-backend-string-contains? asm "tl_alloc")
                        (compiler-backend-string-contains? asm "main"))]
                    [(ErrCompilerDriver _) false])]
                (begin
                  (compiler-driver-state-reset-file-state! state-a)
                  emitted-ok))))]
        [(ErrCompilerLower _) false]))))

(define (main) : i64
  (begin
    (unless (compiler-driver-state-smoke-cache-isolated?) (return 2))
    (unless (compiler-driver-state-smoke-reset-flags-isolated?) (return 3))
    (unless
      (compiler-driver-state-smoke-load-session-storage-isolated?)
      (return 6))
    (unless (compiler-driver-state-smoke-pools-isolated?) (return 4))
    (unless (compiler-driver-state-smoke-type-dedup-isolated?) (return 5))
    (unless (compiler-driver-state-smoke-active-pools-isolated?) (return 7))
    (unless (compiler-driver-state-smoke-builtins-isolated?) (return 8))
    (unless
      (compiler-driver-state-smoke-builtins-scratch-capture-stable?)
      (return 10))
    (unless (compiler-driver-state-smoke-lower-arenas-isolated?) (return 9))
    (unless
      (compiler-driver-state-smoke-lowered-result-pools-survive-reset?)
      (return 11))
    42))