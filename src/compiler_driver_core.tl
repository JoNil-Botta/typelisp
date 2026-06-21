;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.
(import "../stdlib/io.tl")
(import "../stdlib/arena.tl")
(import "../stdlib/string.tl")
(cfg compile-profile (import "../stdlib/profile.tl"))
(import "compiler_backend.tl")
(import "compiler_diagnostic.tl")
(import "compiler_load.tl")
(import "compiler_optimize.tl")
(import "../stdlib/text_buf.tl")

(defenum ResultCompilerDriver
  (OkCompilerDriver String)
  (ErrCompilerDriver CompilerDiagnostic))

(defenum ResultCompilerDriverBuffer
  (OkCompilerDriverBuffer TextBuf)
  (ErrCompilerDriverBuffer CompilerDiagnostic))

(defenum ResultCompilerDriverPic
  (OkCompilerDriverPic CompilerBackendPicOutput)
  (ErrCompilerDriverPic CompilerDiagnostic))

(defenum ResultCompilerDriverObject
  (OkCompilerDriverObject CompilerObjectImage)
  (ErrCompilerDriverObject CompilerDiagnostic))

(defenum ResultCompilerDriverLowered
  (OkCompilerDriverLowered
    CompilerIrProgram
    CompilerSourceSpans
    AstExprNodePoolState
    AstTypeNodePoolState)
  (ErrCompilerDriverLowered CompilerDiagnostic))

(defstruct CompilerDriverState
  (expr-pool (Array AstExprNodePoolState))
  (type-pool (Array AstTypeNodePoolState))
  (builtin-ids (Array CompilerBuiltinIdsState))
  (lower-arenas (Array CompilerLowerArenaState))
  (load-session CompilerLoadSessionState))

(define (compiler-driver-state-new-from-pools
  [expr-pool : AstExprNodePoolState]
  [type-pool : AstTypeNodePoolState]) : CompilerDriverState
  (let
    [expr-cell : (Array AstExprNodePoolState)
      (make-array AstExprNodePoolState 1)]
    [type-cell : (Array AstTypeNodePoolState)
      (make-array AstTypeNodePoolState 1)]
    [builtin-cell : (Array CompilerBuiltinIdsState)
      (make-array CompilerBuiltinIdsState 1)]
    [lower-cell : (Array CompilerLowerArenaState)
      (make-array CompilerLowerArenaState 1)]
    (begin
      (array-set! expr-cell 0 expr-pool)
      (array-set! type-cell 0 type-pool)
      (array-set! builtin-cell 0 (compiler-builtin-ids-state-new))
      (array-set! lower-cell 0 (compiler-lower-arena-state-new))
      (CompilerDriverState
        expr-cell
        type-cell
        builtin-cell
        lower-cell
        (compiler-load-session-state-new)))))

(define (compiler-driver-state-new) : CompilerDriverState
  (compiler-driver-state-new-from-pools
    (ast-expr-node-pool-state-create 1)
    (ast-type-node-pool-state-create 1)))

(define (compiler-driver-state-new-for-compile) : CompilerDriverState
  (let
    [state : CompilerDriverState
      (compiler-driver-state-new-from-pools
        (ast-node-pool-state-capture)
        (ty-node-pool-state-capture))]
    (begin
      (compiler-builtin-ids-state-capture-from-globals!
        (array-ref (struct-get state builtin-ids) 0))
      (compiler-lower-arena-state-capture-from-globals!
        (array-ref (struct-get state lower-arenas) 0))
      state)))

(define (compiler-driver-state-session-cache-enabled?
  [state : CompilerDriverState]) : bool
  (compiler-load-session-state-cache-enabled? (struct-get state load-session)))

(define (compiler-driver-state-session-cache-enable
  [state : CompilerDriverState]) : CompilerDriverState
  (begin
    (compiler-load-session-state-cache-enable! (struct-get state load-session))
    state))

(define (compiler-driver-state-session-program-cache-enabled?
  [state : CompilerDriverState]) : bool
  (compiler-load-session-state-program-cache-enabled?
    (struct-get state load-session)))

(define (compiler-driver-state-session-program-cache-disable
  [state : CompilerDriverState]) : CompilerDriverState
  (begin
    (compiler-load-session-state-program-cache-disable!
      (struct-get state load-session))
    state))

(define (compiler-driver-state-apply-session-floors!
  [state : CompilerDriverState]) : unit
  (compiler-load-session-state-use! (struct-get state load-session)))

(define (compiler-driver-state-apply-session-flags!
  [state : CompilerDriverState]) : unit
  (compiler-load-session-state-use! (struct-get state load-session)))

(define (compiler-driver-state-install-pools! [state : CompilerDriverState]) : unit
  (ast-node-pools-state-install!
    (array-ref (struct-get state expr-pool) 0)
    (array-ref (struct-get state type-pool) 0)))

(define (compiler-driver-state-pool-context [state : CompilerDriverState]) : AstNodePoolContext
  (ast-node-pool-context-from-cells
    (struct-get state expr-pool)
    (struct-get state type-pool)))

(define (compiler-driver-state-install-builtins! [state : CompilerDriverState]) : unit
  (compiler-builtin-ids-state-install!
    (array-ref (struct-get state builtin-ids) 0)))

(define (compiler-driver-state-install-lower-arenas!
  [state : CompilerDriverState]) : unit
  (compiler-lower-arena-state-install!
    (array-ref (struct-get state lower-arenas) 0)))

(define (compiler-driver-state-capture-active-pools!
  [state : CompilerDriverState]) : unit
  (begin
    (array-set! (struct-get state expr-pool) 0 (ast-node-pool-state-capture))
    (array-set! (struct-get state type-pool) 0 (ty-node-pool-state-capture))))

(define (compiler-driver-state-capture-active-builtins!
  [state : CompilerDriverState]) : unit
  (compiler-builtin-ids-state-capture-from-globals!
    (array-ref (struct-get state builtin-ids) 0)))

(define (compiler-driver-state-capture-active-lower-arenas!
  [state : CompilerDriverState]) : unit
  (compiler-lower-arena-state-capture-from-globals!
    (array-ref (struct-get state lower-arenas) 0)))

(define (compiler-driver-state-install-transients!
  [state : CompilerDriverState]) : unit
  (begin
    (compiler-driver-state-install-builtins! state)
    (compiler-driver-state-install-lower-arenas! state)))

(define (compiler-driver-state-capture-active-transients!
  [state : CompilerDriverState]) : unit
  (begin
    (compiler-driver-state-capture-active-builtins! state)
    (compiler-driver-state-capture-active-lower-arenas! state)))

(define (compiler-driver-state-capture-session-floors!
  [state : CompilerDriverState]) : unit
  (begin
    (compiler-driver-state-capture-active-pools! state)
    (compiler-driver-state-capture-active-transients! state)
    (compiler-load-session-state-use! (struct-get state load-session))))

(define (compiler-driver-lowered-from-active-pools
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]) : ResultCompilerDriverLowered
  (OkCompilerDriverLowered
    program
    spans
    (ast-node-pool-state-capture)
    (ty-node-pool-state-capture)))

(define (compiler-driver-install-lowered-pools!
  [expr-pool : AstExprNodePoolState]
  [type-pool : AstTypeNodePoolState]) : unit
  (ast-node-pools-state-install! expr-pool type-pool))

(define (compiler-driver-runtime-prelude-cache-lookup [key : String]) : CompilerLoadPreludeCacheLookup
  (compiler-load-runtime-prelude-cache-lookup key))

(define (compiler-driver-runtime-prelude-cache-store
  [key : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : SymI64Env]) : unit
  (compiler-load-runtime-prelude-cache-store key decls paths modules seen))

(define (compiler-driver-runtime-prelude-cache-store-with-pools
  [key : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : SymI64Env]
  [pools : AstNodePoolContext]) : unit
  (compiler-load-runtime-prelude-cache-store-with-pools
    key
    decls
    paths
    modules
    seen
    pools))

(define (compiler-driver-ty-node-pool-exhausted-diagnostic
  [input-path : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start input-path (ty-node-pool-exhausted-message)))

(define (compiler-driver-reset-file-state!) : unit
  (begin
    ;; Compatibility reset for serial standalone helpers. Driver-state callers
    ;; install their active state before this and capture it again afterward.
    (compiler-load-session-reset-pools!)
    (compiler-load-session-reset-interns!)
    (compiler-builtin-reset!)
    ;; #2596/#3259: drop the previous entry's lowerer arenas. At opt level 0
    ;; the escaped IR stays alive until the next file reset.
    (lower-arenas-release!)))

(define (compiler-driver-state-reset-file-state! [state : CompilerDriverState]) : unit
  (let
    [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
    (begin
      (compiler-driver-state-apply-session-flags! state)
      (compiler-load-session-reset-pools-with-pools! pools)
      (compiler-driver-state-install-pools! state)
      (compiler-load-session-reset-interns!)
      (compiler-driver-state-install-transients! state)
      (compiler-builtin-reset!)
      ;; #2596/#3259: drop the previous entry's lowerer arenas. At opt level 0
      ;; the escaped IR stays alive until the next file reset.
      (lower-arenas-release!)
      (compiler-driver-state-capture-active-transients! state))))

(cfg
  compile-profile
  (define compiler-driver-profile-total-start-ms : i64
    0))
(cfg
  compile-profile
  (define compiler-driver-profile-total-start-total : i64
    0))
(cfg
  compile-profile
  (define compiler-driver-profile-total-start-live : i64
    0))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-ms : i64
    0))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-total : i64
    0))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-live : i64
    0))
(cfg
  compile-profile
  (define compiler-driver-profile-best-peak : i64
    0))

(cfg
  compile-profile
  (define (compiler-driver-profile-max [left : i64] [right : i64]) : i64
    (if (> left right)
      left
      right)))

(cfg
  compile-profile
  (define (compiler-driver-profile-nonnegative [value : i64]) : i64
    (if (< value 0)
      0
      value)))

(cfg
  compile-profile
  (define (compiler-driver-profile-field [value : i64]) : String
    (string-append "|" (int->string value))))

(cfg
  compile-profile
  (define (compiler-driver-profile-line
    [phase : String]
    [elapsed-ms : i64]
    [alloc-delta : i64]
    [live-delta : i64]
    [peak-delta : i64]) : String
    (string-append
      "compile-profile|"
      (string-append
        phase
        (string-append
          (compiler-driver-profile-field elapsed-ms)
          (string-append
            (compiler-driver-profile-field alloc-delta)
            (string-append
              (compiler-driver-profile-field live-delta)
              (string-append (compiler-driver-profile-field peak-delta) "\n"))))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-phase) : unit
    (begin
      (set! compiler-driver-profile-phase-start-ms (profile-now-ms))
      (set! compiler-driver-profile-phase-start-total (profile-alloc-total))
      (set! compiler-driver-profile-phase-start-live (profile-alloc-live))
      (profile-alloc-reset-peak))))

(cfg
  compile-profile
  (define (compiler-driver-profile-finish-phase [phase : String]) : unit
    (let
      [end-ms : i64 (profile-now-ms)]
      [end-total : i64 (profile-alloc-total)]
      [end-live : i64 (profile-alloc-live)]
      [peak-delta : i64
        (compiler-driver-profile-nonnegative
          (- (profile-alloc-peak) compiler-driver-profile-phase-start-live))]
      (begin
        (set!
          compiler-driver-profile-best-peak
          (compiler-driver-profile-max
            compiler-driver-profile-best-peak
            peak-delta))
        (print-error
          (compiler-driver-profile-line
            phase
            (- end-ms compiler-driver-profile-phase-start-ms)
            (- end-total compiler-driver-profile-phase-start-total)
            (- end-live compiler-driver-profile-phase-start-live)
            peak-delta))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-total) : unit
    (begin
      (set! compiler-driver-profile-total-start-ms (profile-now-ms))
      (set! compiler-driver-profile-total-start-total (profile-alloc-total))
      (set! compiler-driver-profile-total-start-live (profile-alloc-live))
      (set! compiler-driver-profile-best-peak 0)
      (print-error
        "compile-profile|phase|elapsed_ms|alloc_delta_bytes|live_delta_bytes|peak_live_delta_bytes\n")
      (compiler-driver-profile-start-phase))))

(cfg
  compile-profile
  (define (compiler-driver-profile-finish-total) : unit
    (print-error
      (compiler-driver-profile-line
        "total"
        (- (profile-now-ms) compiler-driver-profile-total-start-ms)
        (- (profile-alloc-total) compiler-driver-profile-total-start-total)
        (- (profile-alloc-live) compiler-driver-profile-total-start-live)
        compiler-driver-profile-best-peak))))

(define (compiler-driver-lower-mode-for-target
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]) : CompilerLowerMode
  (match mode
    [(BackendModeAvx2)
      (match target
        [(BackendTargetLinux) (CompilerLowerLinuxAvx2)]
        [(BackendTargetWindows) (CompilerLowerWindowsAvx2)])]
    [(BackendModeAvx512)
      (match target
        [(BackendTargetLinux) (CompilerLowerLinuxAvx512)]
        [(BackendTargetWindows) (CompilerLowerWindowsAvx512)])]
    [_
      (match target
        [(BackendTargetLinux) (CompilerLowerLinuxScalar)]
        [(BackendTargetWindows) (CompilerLowerWindowsScalar)])]))

(define (compiler-driver-enable-linux-cfgs [cfgs : SymI64Env]) : SymI64Env
  (compiler-cfg-enable
    (compiler-cfg-enable
      (compiler-cfg-enable (compiler-cfg-enable cfgs "linux") "unix")
      "target-linux")
    "os-linux"))

(define (compiler-driver-enable-windows-cfgs [cfgs : SymI64Env]) : SymI64Env
  (compiler-cfg-enable
    (compiler-cfg-enable (compiler-cfg-enable cfgs "windows") "target-windows")
    "os-windows"))

(define (compiler-driver-enable-language-cfgs [cfgs : SymI64Env]) : SymI64Env
  (compiler-cfg-enable
    (compiler-cfg-enable
      (compiler-cfg-enable cfgs "feature-ptr-addr-of")
      "feature-str-view")
    "feature-private-string-intrinsics"))

(define (compiler-driver-target-cfgs
  [target : CompilerBackendTarget]
  [cfgs : SymI64Env]) : SymI64Env
  (compiler-driver-enable-language-cfgs
    (match target
      [(BackendTargetLinux) (compiler-driver-enable-linux-cfgs cfgs)]
      [(BackendTargetWindows) (compiler-driver-enable-windows-cfgs cfgs)])))

(define (compiler-driver-emit-lowered
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-with-level
    input-path
    program
    spans
    target
    has-target
    (compiler-optimize-default-level)))

(define (compiler-driver-emit-lowered-with-level
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-with-level-and-entry
    input-path
    program
    spans
    target
    has-target
    opt-level
    true))

(define (compiler-driver-emit-lowered-with-level-and-entry
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [opt-level : i64]
  [emit-entry : bool]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-with-level-mode-and-entry
    input-path
    program
    spans
    target
    has-target
    (BackendModeScalar)
    opt-level
    emit-entry))

;; #2596: the lowered IR functions live in a dedicated arena
;; (lower-ir-arena); at opt levels >= 1 the optimizer deep-clones every
;; surviving function out of it, so the arena is dead weight (~172MB on a
;; cli.tl self-compile) once optimization returns. At level 0 the lowered
;; program flows to the backend unchanged and the arena must stay alive.
(define (compiler-driver-release-lowered-ir! [opt-level : i64]) : unit
  (if (>= opt-level 1)
    (lower-ir-arena-release!)
    unit))

(define (compiler-driver-emit-lowered-with-level-mode-and-entry
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-with-level-mode-entry-and-crt
    input-path
    program
    spans
    target
    has-target
    mode
    opt-level
    emit-entry
    false))

(define (compiler-driver-emit-lowered-with-level-mode-entry-and-crt
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriver
  (if (ty-node-pool-exhausted?)
    (ErrCompilerDriver
      (compiler-driver-ty-node-pool-exhausted-diagnostic input-path))
    (begin
      (cfg compile-profile (compiler-driver-profile-start-phase))
      (match (optimize-program-with-spans-and-level program spans opt-level)
        [(CompilerOptimizedProgram optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ty-node-pool-exhausted?)
              (ErrCompilerDriver
                (compiler-driver-ty-node-pool-exhausted-diagnostic input-path))
              (begin
                (compiler-backend-set-scalar-registers! (>= opt-level 2))
                (cfg compile-profile (compiler-driver-profile-start-phase))
                (match (if has-target
                  (compiler-backend-emit-program-target-with-mode-and-crt
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry)
                  (compiler-backend-emit-program-target-with-mode-and-crt
                    optimized
                    (BackendTargetLinux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry))
                  [(OkCompilerBackend asm)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (OkCompilerDriver asm))]
                  [(ErrCompilerBackend diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ErrCompilerDriver
                        (compiler-diagnostic-with-path diag input-path)))]))))]))))

(define (compiler-driver-emit-lowered-buffer-with-level-mode-and-entry
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]) : ResultCompilerDriverBuffer
  (if (ty-node-pool-exhausted?)
    (ErrCompilerDriverBuffer
      (compiler-driver-ty-node-pool-exhausted-diagnostic input-path))
    (begin
      (cfg compile-profile (compiler-driver-profile-start-phase))
      (match (optimize-program-with-spans-and-level program spans opt-level)
        [(CompilerOptimizedProgram optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ty-node-pool-exhausted?)
              (ErrCompilerDriverBuffer
                (compiler-driver-ty-node-pool-exhausted-diagnostic input-path))
              (begin
                (compiler-backend-set-scalar-registers! (>= opt-level 2))
                (cfg compile-profile (compiler-driver-profile-start-phase))
                (match (if has-target
                  (compiler-backend-emit-program-target-with-mode-buffer
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry)
                  (compiler-backend-emit-program-target-with-mode-buffer
                    optimized
                    (BackendTargetLinux)
                    mode
                    optimized-spans
                    emit-entry))
                  [(OkCompilerBackendBuffer buf)
                    (let
                      [peepholed : TextBuf
                        (compiler-backend-peephole-text-buf buf)]
                      (begin
                        (cfg
                          compile-profile
                          (compiler-driver-profile-finish-phase "backend"))
                        (OkCompilerDriverBuffer peepholed)))]
                  [(ErrCompilerBackendBuffer diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ErrCompilerDriverBuffer
                        (compiler-diagnostic-with-path diag input-path)))]))))]))))

(define (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverObject
  (if (ty-node-pool-exhausted?)
    (ErrCompilerDriverObject
      (compiler-driver-ty-node-pool-exhausted-diagnostic input-path))
    (begin
      (cfg compile-profile (compiler-driver-profile-start-phase))
      (match (optimize-program-with-spans-and-level program spans opt-level)
        [(CompilerOptimizedProgram optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ty-node-pool-exhausted?)
              (ErrCompilerDriverObject
                (compiler-driver-ty-node-pool-exhausted-diagnostic input-path))
              (begin
                (compiler-backend-set-scalar-registers! (>= opt-level 2))
                (cfg compile-profile (compiler-driver-profile-start-phase))
                (match (if has-target
                  (compiler-backend-emit-program-object-image-target-with-mode-and-crt
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry)
                  (compiler-backend-emit-program-object-image-target-with-mode-and-crt
                    optimized
                    (BackendTargetLinux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry))
                  [(OkCompilerBackendObject image)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (OkCompilerDriverObject image))]
                  [(ErrCompilerBackendObject diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ErrCompilerDriverObject
                        (compiler-diagnostic-with-path diag input-path)))]))))]))))

(define (compiler-driver-emit-lowered-pic-with-level-mode-entry-and-crt
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverPic
  (if (ty-node-pool-exhausted?)
    (ErrCompilerDriverPic
      (compiler-driver-ty-node-pool-exhausted-diagnostic input-path))
    (begin
      (cfg compile-profile (compiler-driver-profile-start-phase))
      (match (optimize-program-with-spans-and-level program spans opt-level)
        [(CompilerOptimizedProgram optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ty-node-pool-exhausted?)
              (ErrCompilerDriverPic
                (compiler-driver-ty-node-pool-exhausted-diagnostic input-path))
              (begin
                (compiler-backend-set-scalar-registers! (>= opt-level 2))
                (cfg compile-profile (compiler-driver-profile-start-phase))
                (match (if has-target
                  (compiler-backend-emit-program-pic-target-with-mode-and-crt
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry)
                  (compiler-backend-emit-program-pic-target-with-mode-and-crt
                    optimized
                    (BackendTargetLinux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry))
                  [(OkCompilerBackendPic output)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (OkCompilerDriverPic output))]
                  [(ErrCompilerBackendPic diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ErrCompilerDriverPic
                        (compiler-diagnostic-with-path diag input-path)))]))))]))))

(define (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriver
  (match lowered
    [(OkCompilerDriverLowered program spans expr-pool type-pool)
      (begin
        (compiler-driver-install-lowered-pools! expr-pool type-pool)
        (compiler-driver-emit-lowered-with-level-mode-entry-and-crt
          input-path
          program
          spans
          target
          has-target
          mode
          opt-level
          emit-entry
          crt-entry))]
    [(ErrCompilerDriverLowered diag) (ErrCompilerDriver diag)]))

(define (compiler-driver-emit-lowered-result-buffer-with-level-mode-and-entry
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]) : ResultCompilerDriverBuffer
  (match lowered
    [(OkCompilerDriverLowered program spans expr-pool type-pool)
      (begin
        (compiler-driver-install-lowered-pools! expr-pool type-pool)
        (compiler-driver-emit-lowered-buffer-with-level-mode-and-entry
          input-path
          program
          spans
          target
          has-target
          mode
          opt-level
          emit-entry))]
    [(ErrCompilerDriverLowered diag) (ErrCompilerDriverBuffer diag)]))

(define (compiler-driver-emit-lowered-result-object-image-with-level-mode-entry-and-crt
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverObject
  (match lowered
    [(OkCompilerDriverLowered program spans expr-pool type-pool)
      (begin
        (compiler-driver-install-lowered-pools! expr-pool type-pool)
        (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt
          input-path
          program
          spans
          target
          has-target
          mode
          opt-level
          emit-entry
          crt-entry))]
    [(ErrCompilerDriverLowered diag) (ErrCompilerDriverObject diag)]))

(define (compiler-driver-emit-lowered-result-pic-with-level-mode-entry-and-crt
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverPic
  (match lowered
    [(OkCompilerDriverLowered program spans expr-pool type-pool)
      (begin
        (compiler-driver-install-lowered-pools! expr-pool type-pool)
        (compiler-driver-emit-lowered-pic-with-level-mode-entry-and-crt
          input-path
          program
          spans
          target
          has-target
          mode
          opt-level
          emit-entry
          crt-entry))]
    [(ErrCompilerDriverLowered diag) (ErrCompilerDriverPic diag)]))

;; The implicit prelude prepended before every entry program. It is two
;; always-linked stdlib modules loaded as files:
;;   - stdlib/runtime.tl  - fault/abort handlers + OS primitives (#2142 / #2150),
;;     exported as fixed symbols (#2143); kept as reachability roots.
;;   - stdlib/core_macros.tl - the implicit core macro prelude (#2060): `and`,
;;     `or`, `when`, `unless`, `cond`. Loaded right after runtime so its macros
;;     are source-order visible to the entry and resolve as bare unqualified
;;     calls via the prelude fallback in `macro-call-decl`.
;; Loading the prelude first lets the entry's own (possibly transitive) imports
;; dedup against it before the decls/paths/modules are concatenated.
(define (compiler-driver-load-runtime-prelude-cold
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-file-with-paths-and-roots-cfg
    "stdlib/runtime.tl"
    (sym-i64-empty)
    stdlib-roots
    cfgs)
    [(OkCompilerLoadWithPaths
        runtime-decls
        runtime-paths
        runtime-modules
        runtime-seen)
      (match (compiler-load-core-macro-prelude-with-roots-cfg
        runtime-seen
        stdlib-roots
        cfgs)
        [(OkCompilerLoadWithPaths
            macro-decls
            macro-paths
            macro-modules
            macro-seen)
          (OkCompilerLoadWithPaths
            (compiler-load-decl-list-append runtime-decls macro-decls)
            (compiler-load-decl-path-list-append runtime-paths macro-paths)
            (compiler-load-decl-module-list-append
              runtime-modules
              macro-modules)
            macro-seen)]
        [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-driver-load-runtime-prelude-cache-miss
  [key : String]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [prev-arena : i64 (arena-current)]
    [loaded : ResultCompilerLoadWithPaths
      (begin
        (unsafe
          (arena-set! node-pool-base-arena))
        (let
          [persistent-key : String (string-copy-borrowed (& key))]
          [cold : ResultCompilerLoadWithPaths
            (compiler-driver-load-runtime-prelude-cold stdlib-roots cfgs)]
          (begin
            (match cold
              [(OkCompilerLoadWithPaths decls paths modules seen)
                (compiler-driver-runtime-prelude-cache-store
                  persistent-key
                  decls
                  paths
                  modules
                  seen)]
              [(ErrCompilerLoadWithPaths _) unit])
            (unsafe
              (arena-set! prev-arena))
            cold)))]
    loaded))

(define (compiler-driver-load-runtime-prelude
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (if (compiler-load-session-cache-enabled?)
    (let
      [key : String
        (compiler-load-prelude-cache-key "runtime-prelude" stdlib-roots cfgs)]
      (match (compiler-driver-runtime-prelude-cache-lookup key)
        [(CompilerLoadPreludeCacheHit decls paths modules seen)
          (OkCompilerLoadWithPaths decls paths modules seen)]
        [(CompilerLoadPreludeCacheMiss)
          (compiler-driver-load-runtime-prelude-cache-miss
            key
            stdlib-roots
            cfgs)]))
    (compiler-driver-load-runtime-prelude-cold stdlib-roots cfgs)))

(define (compiler-driver-load-file-with-runtime
  [input-path : String]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  ;; Prepend the implicit prelude (runtime + core macros), then load the entry.
  (match (compiler-driver-load-runtime-prelude stdlib-roots cfgs)
    [(OkCompilerLoadWithPaths
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler-load-entry-file-with-paths-and-roots-cfg
        input-path
        prelude-seen
        stdlib-roots
        cfgs)
        [(OkCompilerLoadWithPaths entry-decls entry-paths entry-modules seen)
          (OkCompilerLoadWithPaths
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-driver-load-source-with-runtime
  [input-path : String]
  [source : String]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-driver-load-runtime-prelude stdlib-roots cfgs)
    [(OkCompilerLoadWithPaths
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler-load-source-with-paths-and-roots-cfg
        input-path
        source
        prelude-seen
        stdlib-roots
        cfgs)
        [(OkCompilerLoadWithPaths entry-decls entry-paths entry-modules seen)
          (OkCompilerLoadWithPaths
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-driver-load-file-for-pic-image
  [input-path : String]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-core-macro-prelude-with-roots-cfg
    (sym-i64-empty)
    stdlib-roots
    cfgs)
    [(OkCompilerLoadWithPaths
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler-load-entry-file-with-paths-and-roots-cfg
        input-path
        prelude-seen
        stdlib-roots
        cfgs)
        [(OkCompilerLoadWithPaths entry-decls entry-paths entry-modules seen)
          (OkCompilerLoadWithPaths
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-driver-load-runtime-prelude-cold-with-pools
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-load-file-with-paths-and-roots-cfg-with-pools
    "stdlib/runtime.tl"
    (sym-i64-empty)
    stdlib-roots
    cfgs
    pools)
    [(OkCompilerLoadWithPaths
        runtime-decls
        runtime-paths
        runtime-modules
        runtime-seen)
      (match (compiler-load-core-macro-prelude-with-roots-cfg-with-pools
        runtime-seen
        stdlib-roots
        cfgs
        pools)
        [(OkCompilerLoadWithPaths
            macro-decls
            macro-paths
            macro-modules
            macro-seen)
          (OkCompilerLoadWithPaths
            (compiler-load-decl-list-append runtime-decls macro-decls)
            (compiler-load-decl-path-list-append runtime-paths macro-paths)
            (compiler-load-decl-module-list-append
              runtime-modules
              macro-modules)
            macro-seen)]
        [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-driver-load-runtime-prelude-cache-miss-with-pools
  [key : String]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (let
    [prev-arena : i64 (arena-current)]
    [loaded : ResultCompilerLoadWithPaths
      (begin
        (unsafe
          (arena-set! (ast-node-pool-context-base-arena pools)))
        (let
          [persistent-key : String (string-copy-borrowed (& key))]
          [cold : ResultCompilerLoadWithPaths
            (compiler-driver-load-runtime-prelude-cold-with-pools
              stdlib-roots
              cfgs
              pools)]
          (begin
            (match cold
              [(OkCompilerLoadWithPaths decls paths modules seen)
                (compiler-driver-runtime-prelude-cache-store-with-pools
                  persistent-key
                  decls
                  paths
                  modules
                  seen
                  pools)]
              [(ErrCompilerLoadWithPaths _) unit])
            (unsafe
              (arena-set! prev-arena))
            cold)))]
    loaded))

(define (compiler-driver-load-runtime-prelude-with-pools
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (if (compiler-load-session-cache-enabled?)
    (let
      [key : String
        (compiler-load-prelude-cache-key "runtime-prelude" stdlib-roots cfgs)]
      (match (compiler-driver-runtime-prelude-cache-lookup key)
        [(CompilerLoadPreludeCacheHit decls paths modules seen)
          (OkCompilerLoadWithPaths decls paths modules seen)]
        [(CompilerLoadPreludeCacheMiss)
          (compiler-driver-load-runtime-prelude-cache-miss-with-pools
            key
            stdlib-roots
            cfgs
            pools)]))
    (compiler-driver-load-runtime-prelude-cold-with-pools
      stdlib-roots
      cfgs
      pools)))

(define (compiler-driver-load-file-with-runtime-with-pools
  [input-path : String]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-driver-load-runtime-prelude-with-pools
    stdlib-roots
    cfgs
    pools)
    [(OkCompilerLoadWithPaths
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
        input-path
        prelude-seen
        stdlib-roots
        cfgs
        pools)
        [(OkCompilerLoadWithPaths entry-decls entry-paths entry-modules seen)
          (OkCompilerLoadWithPaths
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-driver-load-source-with-runtime-with-pools
  [input-path : String]
  [source : String]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-driver-load-runtime-prelude-with-pools
    stdlib-roots
    cfgs
    pools)
    [(OkCompilerLoadWithPaths
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
        input-path
        source
        prelude-seen
        stdlib-roots
        AstNoModuleName
        cfgs
        pools)
        [(OkCompilerLoadWithPaths entry-decls entry-paths entry-modules seen)
          (OkCompilerLoadWithPaths
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-driver-load-file-for-pic-image-with-pools
  [input-path : String]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-load-core-macro-prelude-with-roots-cfg-with-pools
    (sym-i64-empty)
    stdlib-roots
    cfgs
    pools)
    [(OkCompilerLoadWithPaths
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
        input-path
        prelude-seen
        stdlib-roots
        cfgs
        pools)
        [(OkCompilerLoadWithPaths entry-decls entry-paths entry-modules seen)
          (OkCompilerLoadWithPaths
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-driver-load-and-lower-escaping
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriverLowered
  (match (compiler-driver-load-file-with-runtime input-path stdlib-roots cfgs)
    [(OkCompilerLoadWithPaths decls paths _ _)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
        (cfg compile-profile (compiler-driver-profile-start-phase))
        (match (lower-compiler-program-with-decl-paths-mode-cache
          input-path
          (ast-program decls)
          paths
          (compiler-driver-lower-mode-for-target target mode)
          stdlib-roots
          (compiler-load-prelude-cache-key
            "typecheck-prefix-lower"
            stdlib-roots
            cfgs))
          [(OkCompilerLower program spans)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase "lower"))
              (if (ty-node-pool-exhausted?)
                (ErrCompilerDriverLowered
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path))
                (compiler-driver-lowered-from-active-pools program spans)))]
          [(ErrCompilerLower diag)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase "lower"))
              (ErrCompilerDriverLowered diag))]))]
    [(ErrCompilerLoadWithPaths diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
        (ErrCompilerDriverLowered diag))]))

(define (compiler-driver-load-and-lower-pic-image
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriverLowered
  (match (compiler-driver-load-file-for-pic-image input-path stdlib-roots cfgs)
    [(OkCompilerLoadWithPaths decls paths _ _)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
        (cfg compile-profile (compiler-driver-profile-start-phase))
        (match (lower-compiler-program-with-decl-paths-mode-cache
          input-path
          (ast-program decls)
          paths
          (compiler-driver-lower-mode-for-target target mode)
          stdlib-roots
          (compiler-load-prelude-cache-key
            "typecheck-prefix-lower"
            stdlib-roots
            cfgs))
          [(OkCompilerLower program spans)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase "lower"))
              (if (ty-node-pool-exhausted?)
                (ErrCompilerDriverLowered
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path))
                (compiler-driver-lowered-from-active-pools program spans)))]
          [(ErrCompilerLower diag)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase "lower"))
              (ErrCompilerDriverLowered diag))]))]
    [(ErrCompilerLoadWithPaths diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
        (ErrCompilerDriverLowered diag))]))

(define (compiler-driver-load-and-lower-escaping-with-state
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriverLowered
  (let
    [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
    (match (compiler-driver-load-file-with-runtime-with-pools
      input-path
      stdlib-roots
      cfgs
      pools)
      [(OkCompilerLoadWithPaths decls paths _ _)
        (begin
          (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
          (cfg compile-profile (compiler-driver-profile-start-phase))
          (compiler-driver-state-install-pools! state)
          (compiler-driver-state-install-transients! state)
          (match (lower-compiler-program-with-decl-paths-mode-cache
            input-path
            (ast-program decls)
            paths
            (compiler-driver-lower-mode-for-target target mode)
            stdlib-roots
            (compiler-load-prelude-cache-key
              "typecheck-prefix-lower"
              stdlib-roots
              cfgs))
            [(OkCompilerLower program spans)
              (begin
                (cfg
                  compile-profile
                  (compiler-driver-profile-finish-phase "lower"))
                (if (ty-node-pool-exhausted?)
                  (ErrCompilerDriverLowered
                    (compiler-driver-ty-node-pool-exhausted-diagnostic
                      input-path))
                  (compiler-driver-lowered-from-active-pools program spans)))]
            [(ErrCompilerLower diag)
              (begin
                (cfg
                  compile-profile
                  (compiler-driver-profile-finish-phase "lower"))
                (ErrCompilerDriverLowered diag))]))]
      [(ErrCompilerLoadWithPaths diag)
        (begin
          (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
          (ErrCompilerDriverLowered diag))])))

(define (compiler-driver-load-and-lower-pic-image-with-state
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriverLowered
  (let
    [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
    (match (compiler-driver-load-file-for-pic-image-with-pools
      input-path
      stdlib-roots
      cfgs
      pools)
      [(OkCompilerLoadWithPaths decls paths _ _)
        (begin
          (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
          (cfg compile-profile (compiler-driver-profile-start-phase))
          (compiler-driver-state-install-pools! state)
          (compiler-driver-state-install-transients! state)
          (match (lower-compiler-program-with-decl-paths-mode-cache
            input-path
            (ast-program decls)
            paths
            (compiler-driver-lower-mode-for-target target mode)
            stdlib-roots
            (compiler-load-prelude-cache-key
              "typecheck-prefix-lower"
              stdlib-roots
              cfgs))
            [(OkCompilerLower program spans)
              (begin
                (cfg
                  compile-profile
                  (compiler-driver-profile-finish-phase "lower"))
                (if (ty-node-pool-exhausted?)
                  (ErrCompilerDriverLowered
                    (compiler-driver-ty-node-pool-exhausted-diagnostic
                      input-path))
                  (compiler-driver-lowered-from-active-pools program spans)))]
            [(ErrCompilerLower diag)
              (begin
                (cfg
                  compile-profile
                  (compiler-driver-profile-finish-phase "lower"))
                (ErrCompilerDriverLowered diag))]))]
      [(ErrCompilerLoadWithPaths diag)
        (begin
          (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
          (ErrCompilerDriverLowered diag))])))

(define (compiler-driver-emit-file-with-target
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    target
    has-target
    (string-vec-new)))

(define (compiler-driver-emit-file-with-target-and-roots
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-and-level
    input-path
    target
    has-target
    stdlib-roots
    (compiler-optimize-default-level)))

(define (compiler-driver-emit-file-with-target-roots-and-level
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-level-and-mode
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    (BackendModeScalar)))

(define (compiler-driver-emit-file-with-target-roots-level-and-mode
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    mode
    (compiler-cfg-empty)
    false))

(define (compiler-driver-emit-file-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    mode
    cfgs
    false))

(define (compiler-driver-emit-file-with-target-roots-level-mode-and-crt
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [crt-entry : bool]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    mode
    (compiler-cfg-empty)
    crt-entry))

(define (compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]
  [crt-entry : bool]) : ResultCompilerDriver
  (begin
    (cfg compile-profile (compiler-driver-profile-start-total))
    ;; The lowering provenance side table (#605/#761) is remapped after
    ;; optimization so backend diagnostics report surviving instruction
    ;; locations when a rewrite can preserve them.
    (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
      input-path
      (compiler-driver-load-and-lower-escaping
        input-path
        target
        stdlib-roots
        mode
        (compiler-driver-target-cfgs target cfgs))
      target
      has-target
      mode
      opt-level
      true
      crt-entry)))

(define (compiler-driver-emit-file-buffer-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriverBuffer
  (begin
    (cfg compile-profile (compiler-driver-profile-start-total))
    (compiler-driver-emit-lowered-result-buffer-with-level-mode-and-entry
      input-path
      (compiler-driver-load-and-lower-escaping
        input-path
        target
        stdlib-roots
        mode
        (compiler-driver-target-cfgs target cfgs))
      target
      has-target
      mode
      opt-level
      true)))

(define (compiler-driver-emit-file-object-image-with-target-roots-level-mode-cfg-and-crt
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]
  [crt-entry : bool]) : ResultCompilerDriverObject
  (begin
    (cfg compile-profile (compiler-driver-profile-start-total))
    (compiler-driver-emit-lowered-result-object-image-with-level-mode-entry-and-crt
      input-path
      (compiler-driver-load-and-lower-escaping
        input-path
        target
        stdlib-roots
        mode
        (compiler-driver-target-cfgs target cfgs))
      target
      has-target
      mode
      opt-level
      true
      crt-entry)))

(define (compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriverPic
  (begin
    (cfg compile-profile (compiler-driver-profile-start-total))
    (compiler-driver-emit-lowered-result-pic-with-level-mode-entry-and-crt
      input-path
      (compiler-driver-load-and-lower-pic-image
        input-path
        target
        stdlib-roots
        mode
        (compiler-driver-target-cfgs target cfgs))
      target
      has-target
      mode
      opt-level
      false
      false)))

(define (compiler-driver-state-emit-file-buffer-with-target-roots-level-mode-and-cfg
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriverBuffer
  (begin
    (cfg compile-profile (compiler-driver-profile-start-total))
    (compiler-driver-emit-lowered-result-buffer-with-level-mode-and-entry
      input-path
      (compiler-driver-load-and-lower-escaping-with-state
        state
        input-path
        target
        stdlib-roots
        mode
        (compiler-driver-target-cfgs target cfgs))
      target
      has-target
      mode
      opt-level
      true)))

(define (compiler-driver-state-emit-file-pic-with-target-roots-level-mode-and-cfg
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriverPic
  (begin
    (cfg compile-profile (compiler-driver-profile-start-total))
    (compiler-driver-emit-lowered-result-pic-with-level-mode-entry-and-crt
      input-path
      (compiler-driver-load-and-lower-pic-image-with-state
        state
        input-path
        target
        stdlib-roots
        mode
        (compiler-driver-target-cfgs target cfgs))
      target
      has-target
      mode
      opt-level
      false
      false)))

(define (compiler-driver-emit-package-file-with-target-roots-and-level
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]) : ResultCompilerDriver
  (compiler-driver-emit-package-file-with-target-roots-level-and-crt
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    manifest-dir
    package-owner
    deps
    emit-entry
    false))

(define (compiler-driver-emit-package-file-with-target-roots-level-and-crt
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriver
  (compiler-driver-emit-package-file-with-target-roots-level-mode-and-crt
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    (BackendModeScalar)
    manifest-dir
    package-owner
    deps
    emit-entry
    crt-entry))

(define (compiler-driver-emit-package-loaded
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
    input-path
    (compiler-driver-lower-package-loaded input-path target mode decls paths)
    target
    has-target
    mode
    opt-level
    emit-entry
    crt-entry))

(define (compiler-driver-lower-package-loaded
  [input-path : String]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultCompilerDriverLowered
  (match (lower-compiler-program-with-decl-paths-mode
    input-path
    (ast-program decls)
    paths
    (compiler-driver-lower-mode-for-target target mode))
    [(OkCompilerLower program spans)
      (compiler-driver-lowered-from-active-pools program spans)]
    [(ErrCompilerLower diag) (ErrCompilerDriverLowered diag)]))

(define (compiler-driver-emit-package-loaded-object-image
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultCompilerDriverObject
  (compiler-driver-emit-lowered-result-object-image-with-level-mode-entry-and-crt
    input-path
    (compiler-driver-lower-package-loaded input-path target mode decls paths)
    target
    has-target
    mode
    opt-level
    emit-entry
    crt-entry))

(define (compiler-driver-emit-package-file-with-target-roots-level-mode-and-crt
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriver
  (match (compiler-driver-load-package-file-with-runtime-owned
    input-path
    target
    stdlib-roots
    manifest-dir
    package-owner
    deps
    emit-entry)
    [(OkCompilerLoadWithPaths decls paths _ _)
      (match (lower-compiler-program-with-decl-paths-mode-cache
        ""
        (ast-program decls)
        paths
        (compiler-driver-lower-mode-for-target target mode)
        stdlib-roots
        (compiler-load-prelude-cache-key
          "typecheck-prefix-lower"
          stdlib-roots
          (compiler-driver-target-cfgs target (compiler-cfg-empty))))
        [(OkCompilerLower program spans)
          (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
            input-path
            (compiler-driver-lowered-from-active-pools program spans)
            target
            has-target
            mode
            opt-level
            emit-entry
            crt-entry)]
        [(ErrCompilerLower diag) (ErrCompilerDriver diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerDriver diag)]))

(define (compiler-driver-load-package-file-with-runtime-cfg
  [input-path : String]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-runtime-cfg
    input-path
    stdlib-roots
    manifest-dir
    deps
    emit-entry
    cfgs))

(define (compiler-driver-load-package-file-with-runtime
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]) : ResultCompilerLoadWithPaths
  (compiler-driver-load-package-file-with-runtime-cfg
    input-path
    stdlib-roots
    manifest-dir
    deps
    emit-entry
    (compiler-driver-target-cfgs target (compiler-cfg-empty))))

(define (compiler-driver-load-package-file-with-runtime-owned
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]) : ResultCompilerLoadWithPaths
  (match (compiler-driver-load-package-file-with-runtime
    input-path
    target
    stdlib-roots
    manifest-dir
    deps
    emit-entry)
    [(OkCompilerLoadWithPaths decls paths modules seen)
      (OkCompilerLoadWithPaths
        decls
        (compiler-load-package-owned-paths-for-decls
          package-owner
          manifest-dir
          stdlib-roots
          input-path
          decls
          paths)
        modules
        seen)]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-driver-load-package-file-with-runtime-owned-cfg
  [input-path : String]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-driver-load-package-file-with-runtime-cfg
    input-path
    stdlib-roots
    manifest-dir
    deps
    emit-entry
    cfgs)
    [(OkCompilerLoadWithPaths decls paths modules seen)
      (OkCompilerLoadWithPaths
        decls
        (compiler-load-package-owned-paths-for-decls
          package-owner
          manifest-dir
          stdlib-roots
          input-path
          decls
          paths)
        modules
        seen)]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-driver-ir-summary-line [name : String] [value : i64]) : String
  (string-append
    name
    (string-append " " (string-append (int->string value) "\n"))))

(define (compiler-driver-ir-summary-render [summary : CompilerIrSummary]) : String
  (let
    [out : String "typelisp-ir-summary v1\n"]
    (begin
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "globals"
            (compiler-ir-summary-globals summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "functions"
            (compiler-ir-summary-functions summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "externs"
            (compiler-ir-summary-externs summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "blocks"
            (compiler-ir-summary-blocks summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "instructions"
            (compiler-ir-summary-instructions summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "vars"
            (compiler-ir-summary-vars summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "empty-blocks"
            (compiler-ir-summary-empty-blocks summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "max-instructions-function"
            (compiler-ir-summary-max-instructions-function summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "max-instructions-block"
            (compiler-ir-summary-max-instructions-block summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "call-arg-entries"
            (compiler-ir-summary-call-arg-entries summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "phi-input-entries"
            (compiler-ir-summary-phi-input-entries summary))))
      (string-append
        out
        (compiler-driver-ir-summary-line
          "score"
          (compiler-ir-summary-score summary))))))

(define (compiler-driver-emit-ir-summary-lowered-with-level
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [opt-level : i64]) : ResultCompilerDriver
  (if (ty-node-pool-exhausted?)
    (ErrCompilerDriver (compiler-driver-ty-node-pool-exhausted-diagnostic ""))
    (match (optimize-program-with-spans-and-level program spans opt-level)
      [(CompilerOptimizedProgram optimized _)
        (begin
          (compiler-driver-release-lowered-ir! opt-level)
          (if (ty-node-pool-exhausted?)
            (ErrCompilerDriver
              (compiler-driver-ty-node-pool-exhausted-diagnostic ""))
            (OkCompilerDriver
              (compiler-driver-ir-summary-render
                (compiler-ir-program-summary optimized)))))])))

(define (compiler-driver-emit-ir-summary-lowered-result-with-level
  [lowered : ResultCompilerDriverLowered]
  [opt-level : i64]) : ResultCompilerDriver
  (match lowered
    [(OkCompilerDriverLowered program spans expr-pool type-pool)
      (begin
        (compiler-driver-install-lowered-pools! expr-pool type-pool)
        (compiler-driver-emit-ir-summary-lowered-with-level
          program
          spans
          opt-level))]
    [(ErrCompilerDriverLowered diag) (ErrCompilerDriver diag)]))

(define (compiler-driver-emit-ir-summary-file-with-roots-and-level
  [input-path : String]
  [stdlib-roots : StringVec]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-ir-summary-file-with-roots-level-and-cfg
    input-path
    stdlib-roots
    opt-level
    (compiler-cfg-empty)))

(define (compiler-driver-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriver
  (match (compiler-load-entry-file-with-paths-and-roots-cfg
    input-path
    (sym-i64-empty)
    stdlib-roots
    (compiler-driver-target-cfgs target cfgs))
    [(OkCompilerLoadWithPaths decls paths _ _)
      (match (lower-compiler-program-with-decl-paths-mode-cache
        input-path
        (ast-program decls)
        paths
        (compiler-driver-lower-mode-for-target target mode)
        stdlib-roots
        (compiler-load-prelude-cache-key
          "typecheck-prefix-lower"
          stdlib-roots
          (compiler-driver-target-cfgs target cfgs)))
        [(OkCompilerLower program spans)
          (compiler-driver-emit-ir-summary-lowered-result-with-level
            (compiler-driver-lowered-from-active-pools program spans)
            opt-level)]
        [(ErrCompilerLower diag) (ErrCompilerDriver diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerDriver diag)]))

(define (compiler-driver-state-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriver
  (let
    [target-cfgs : SymI64Env (compiler-driver-target-cfgs target cfgs)]
    [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
    (match (compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
      input-path
      (sym-i64-empty)
      stdlib-roots
      target-cfgs
      pools)
      [(OkCompilerLoadWithPaths decls paths _ _)
        (begin
          (compiler-driver-state-install-pools! state)
          (compiler-driver-state-install-transients! state)
          (match (lower-compiler-program-with-decl-paths-mode-cache
            input-path
            (ast-program decls)
            paths
            (compiler-driver-lower-mode-for-target target mode)
            stdlib-roots
            (compiler-load-prelude-cache-key
              "typecheck-prefix-lower"
              stdlib-roots
              target-cfgs))
            [(OkCompilerLower program spans)
              (compiler-driver-emit-ir-summary-lowered-result-with-level
                (compiler-driver-lowered-from-active-pools program spans)
                opt-level)]
            [(ErrCompilerLower diag) (ErrCompilerDriver diag)]))]
      [(ErrCompilerLoadWithPaths diag) (ErrCompilerDriver diag)])))

(define (compiler-driver-emit-ir-summary-file-with-roots-level-and-cfg
  [input-path : String]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [cfgs : SymI64Env]) : ResultCompilerDriver
  (compiler-driver-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
    input-path
    (BackendTargetLinux)
    stdlib-roots
    opt-level
    (BackendModeScalar)
    cfgs))

(define (compiler-driver-emit-file [input-path : String]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target input-path (BackendTargetLinux) false))

(define (compiler-driver-emit-file-with-roots
  [input-path : String]
  [stdlib-roots : StringVec]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    (BackendTargetLinux)
    false
    stdlib-roots))

(define (compiler-driver-emit-file-with-roots-and-level
  [input-path : String]
  [stdlib-roots : StringVec]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-and-level
    input-path
    (BackendTargetLinux)
    false
    stdlib-roots
    opt-level))

(define (compiler-driver-emit-file-for-target
  [input-path : String]
  [target : CompilerBackendTarget]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target input-path target true))

(define (compiler-driver-emit-file-for-target-with-roots
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    target
    true
    stdlib-roots))

(define (compiler-driver-emit-file-for-target-with-roots-and-level
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-and-level
    input-path
    target
    true
    stdlib-roots
    opt-level))

(define (compiler-driver-write-text-buf [output-path : String] [buf : TextBuf]) : i64
  (text-buf-write-file output-path buf))

(define (compiler-driver-write-result
  [result : ResultCompilerDriver]
  [output-path : String]) : i64
  (match result
    [(OkCompilerDriver asm)
      (begin
        (cfg compile-profile (compiler-driver-profile-start-phase))
        (write-file output-path asm)
        (cfg compile-profile (compiler-driver-profile-finish-phase "write"))
        (cfg compile-profile (compiler-driver-profile-finish-total))
        (print-string (string-append "Wrote " (string-append output-path "\n")))
        0)]
    [(ErrCompilerDriver diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-total))
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (compiler-driver-write-buffer-result
  [result : ResultCompilerDriverBuffer]
  [output-path : String]) : i64
  (match result
    [(OkCompilerDriverBuffer buf)
      (let
        [status : i64
          (begin
            (cfg compile-profile (compiler-driver-profile-start-phase))
            (compiler-driver-write-text-buf output-path buf))]
        (begin
          (cfg compile-profile (compiler-driver-profile-finish-phase "write"))
          (cfg compile-profile (compiler-driver-profile-finish-total))
          (if (= status 0)
            (begin
              (print-string
                (string-append "Wrote " (string-append output-path "\n")))
              0)
            status)))]
    [(ErrCompilerDriverBuffer diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-total))
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (compiler-driver-pic-fixups-path [output-path : String]) : String
  (string-append output-path ".fixups"))

(define (compiler-driver-write-pic-result
  [result : ResultCompilerDriverPic]
  [output-path : String]) : i64
  (match result
    [(OkCompilerDriverPic output)
      (let
        [fixups-path : String (compiler-driver-pic-fixups-path output-path)]
        (begin
          (cfg compile-profile (compiler-driver-profile-start-phase))
          (write-file output-path (struct-get output asm))
          (write-file fixups-path (struct-get output fixups))
          (cfg compile-profile (compiler-driver-profile-finish-phase "write"))
          (cfg compile-profile (compiler-driver-profile-finish-total))
          (print-string
            (string-append "Wrote " (string-append output-path "\n")))
          (print-string
            (string-append "Wrote " (string-append fixups-path "\n")))
          0))]
    [(ErrCompilerDriverPic diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-total))
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (compiler-driver-compile-file-with-target-roots-level-mode-cfg
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : i64
  (compiler-driver-write-buffer-result
    (compiler-driver-emit-file-buffer-with-target-roots-level-mode-and-cfg
      input-path
      target
      has-target
      stdlib-roots
      opt-level
      mode
      cfgs)
    output-path))

(define (compiler-driver-compile-file-pic-with-target-roots-level-mode-cfg
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : i64
  (compiler-driver-write-pic-result
    (compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
      input-path
      target
      has-target
      stdlib-roots
      opt-level
      mode
      cfgs)
    output-path))

(define (compiler-driver-compile-file
  [input-path : String]
  [output-path : String]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (BackendTargetLinux)
    false
    (string-vec-new)
    (compiler-optimize-default-level)
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-with-roots
  [input-path : String]
  [output-path : String]
  [stdlib-roots : StringVec]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (BackendTargetLinux)
    false
    stdlib-roots
    (compiler-optimize-default-level)
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-with-roots-and-level
  [input-path : String]
  [output-path : String]
  [stdlib-roots : StringVec]
  [opt-level : i64]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (BackendTargetLinux)
    false
    stdlib-roots
    opt-level
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-with-roots-level-and-mode
  [input-path : String]
  [output-path : String]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (BackendTargetLinux)
    false
    stdlib-roots
    opt-level
    mode
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    (string-vec-new)
    (compiler-optimize-default-level)
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target-with-roots
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    stdlib-roots
    (compiler-optimize-default-level)
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target-with-roots-and-level
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [opt-level : i64]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    stdlib-roots
    opt-level
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target-with-roots-level-and-mode
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    stdlib-roots
    opt-level
    mode
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target-with-roots-level-mode-and-cfg
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    stdlib-roots
    opt-level
    mode
    cfgs))