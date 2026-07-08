;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.
(import stdlib.arena)
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector String) as svec)
(cfg compile-profile (import stdlib.profile))
(import "compiler_backend.tl")
(import compiler_builtin_ids as cbi)
(import "compiler_diagnostic.tl")
(import compiler_intern as ci)
(import "compiler_load.tl")
(import "compiler_optimize.tl")
(import stdlib.text_buf)
(import sym_i64_env)

(defenum ResultCompilerDriver
  (Ok String)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCompilerDriverBuffer
  (Ok text_buf.TextBuf)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCompilerDriverPic
  (Ok CompilerBackendPicOutput)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCompilerDriverObject
  (Ok CompilerObjectImage)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCompilerDriverLowered
  (Ok CompilerIrProgram CompilerSourceSpans AstNodePoolContext)
  (Err (Box CompilerDiagnostic)))

(defstruct CompilerDriverState
  (expr-pool (Array AstExprNodePoolState))
  (type-pool (Array AstTypeNodePoolState))
  (intern-state (Array ci.InternCompatState))
  (builtin-ids (Array cbi.CompilerBuiltinIdsState))
  (lower-arenas (Array CompilerLowerArenaState))
  (load-session CompilerLoadSessionState)
  (pool-arena (Array i64)))

(define (compiler-driver-state-new-from-pools-and-arena
  [expr-pool : AstExprNodePoolState]
  [type-pool : AstTypeNodePoolState]
  [pool-arena : i64]) : CompilerDriverState
  (let
    [expr-cell : (Array AstExprNodePoolState)
      (array.make-array AstExprNodePoolState 1)]
    [type-cell : (Array AstTypeNodePoolState)
      (array.make-array AstTypeNodePoolState 1)]
    [intern-cell : (Array ci.InternCompatState)
      (array.make-array ci.InternCompatState 1)]
    [builtin-cell : (Array cbi.CompilerBuiltinIdsState)
      (array.make-array cbi.CompilerBuiltinIdsState 1)]
    [lower-cell : (Array CompilerLowerArenaState)
      (array.make-array CompilerLowerArenaState 1)]
    [pool-arena-cell : (Array i64) (array.make-array i64 1)]
    (begin
      (array-set! expr-cell 0 expr-pool)
      (array-set! type-cell 0 type-pool)
      (array-set! intern-cell 0 (ci.intern-compat-state-new))
      (array-set! builtin-cell 0 (cbi.state-new))
      (array-set! lower-cell 0 (compiler-lower-arena-state-new))
      (array-set! pool-arena-cell 0 pool-arena)
      (CompilerDriverState
        expr-cell
        type-cell
        intern-cell
        builtin-cell
        lower-cell
        (compiler-load-session-state-new)
        pool-arena-cell))))

(define (compiler-driver-state-new-from-pools
  [expr-pool : AstExprNodePoolState]
  [type-pool : AstTypeNodePoolState]) : CompilerDriverState
  (compiler-driver-state-new-from-pools-and-arena expr-pool type-pool 0))

(define (compiler-driver-state-new) : CompilerDriverState
  (compiler-driver-state-new-from-pools
    (ast-expr-node-pool-state-create 1)
    (ast-type-node-pool-state-create 1)))

(define compiler-driver-compile-expr-pool-initial-capacity : i64
  2097152)
(define compiler-driver-compile-type-pool-initial-capacity : i64
  262144)

(define (compiler-driver-state-new-for-compile) : CompilerDriverState
  (let
    [pool-arena : i64 (arena.tl_arena_make)]
    [pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena
        compiler-driver-compile-expr-pool-initial-capacity
        compiler-driver-compile-type-pool-initial-capacity
        pool-arena)]
    [state : CompilerDriverState
      (compiler-driver-state-new-from-pools-and-arena
        (array-ref (struct-get pools expr-pool) 0)
        (array-ref (struct-get pools type-pool) 0)
        (ast-node-pool-context-base-arena pools))]
    (begin
      (cbi.state-capture-from-globals!
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
  (ast-node-pool-context-install! (compiler-driver-state-pool-context state)))

(define (compiler-driver-state-install-interns! [state : CompilerDriverState]) : unit
  (ci.intern-compat-state-install!
    (array-ref (struct-get state intern-state) 0)))

(define (compiler-driver-node-pool-base-arena) : i64
  (ast-node-pool-base-arena-handle))

(define (compiler-driver-state-pool-context [state : CompilerDriverState]) : AstNodePoolContext
  (ast-node-pool-context-from-cells
    (struct-get state expr-pool)
    (struct-get state type-pool)))

(define (compiler-driver-state-owned-pool-arena [state : CompilerDriverState]) : i64
  (array-ref (struct-get state pool-arena) 0))

(define (compiler-driver-state-has-owned-pool-arena?
  [state : CompilerDriverState]) : bool
  (not (= (compiler-driver-state-owned-pool-arena state) 0)))

(define (compiler-driver-state-adopt-pools!
  [state : CompilerDriverState]
  [pools : AstNodePoolContext]) : unit
  (begin
    (array-set!
      (struct-get state pool-arena)
      0
      (ast-node-pool-context-base-arena pools))
    (array-set!
      (struct-get state expr-pool)
      0
      (array-ref (struct-get pools expr-pool) 0))
    (array-set!
      (struct-get state type-pool)
      0
      (array-ref (struct-get pools type-pool) 0))
    (compiler-driver-state-install-pools! state)))

(define (compiler-driver-state-can-release-checked-lower-source-pools?
  [state : CompilerDriverState]) : bool
  (and
    (compiler-driver-state-has-owned-pool-arena? state)
    (not (compiler-driver-state-session-cache-enabled? state))))

(define (compiler-driver-state-new-checked-lower-pools) : AstNodePoolContext
  (let
    [pool-arena : i64 (arena.tl_arena_make)]
    (ast-node-pool-context-new-with-capacities-in-arena
      compiler-driver-compile-expr-pool-initial-capacity
      compiler-driver-compile-type-pool-initial-capacity
      pool-arena)))

(define (compiler-driver-state-destroy-uncommitted-pools!
  [pools : AstNodePoolContext]) : unit
  (unsafe
    (arena.tl_arena_destroy (ast-node-pool-context-base-arena pools))))

(define (compiler-driver-state-clear-pool-backed-caches!) : unit
  (begin
    (compiler-load-session-floors-set! 0 0 0)
    (compiler-load-program-cache-clear!)
    (compiler-load-runtime-prelude-cache-clear!)
    (tc-prefix-snapshot-cache-clear!)))

(define (compiler-driver-state-reset-owned-pool-arena-if-uncached!
  [state : CompilerDriverState]) : unit
  (if (or
    (not (compiler-driver-state-has-owned-pool-arena? state))
    (compiler-driver-state-session-cache-enabled? state))
    unit
    (let
      ;; The pool arena may grow past its first 64 MiB segment during a compile.
      ;; Destroy the installed head we just retired; the runtime root also tracks
      ;; that newest live segment so either head or root handle reclaims the chain.
      [old-newest : i64
        (ast-node-pool-context-base-arena
          (compiler-driver-state-pool-context state))]
      [new-arena : i64 (arena.tl_arena_make)]
      [pools : AstNodePoolContext
        (ast-node-pool-context-new-with-capacities-in-arena
          compiler-driver-compile-expr-pool-initial-capacity
          compiler-driver-compile-type-pool-initial-capacity
          new-arena)]
      (begin
        (compiler-driver-state-clear-pool-backed-caches!)
        (array-set!
          (struct-get state pool-arena)
          0
          (ast-node-pool-context-base-arena pools))
        (array-set!
          (struct-get state expr-pool)
          0
          (array-ref (struct-get pools expr-pool) 0))
        (array-set!
          (struct-get state type-pool)
          0
          (array-ref (struct-get pools type-pool) 0))
        (compiler-driver-state-install-pools! state)
        (unsafe
          (arena.tl_arena_destroy old-newest))))))

(define (compiler-driver-state-reset-owned-intern-arena-if-uncached!
  [state : CompilerDriverState]) : unit
  (if (or
    (not (compiler-driver-state-has-owned-pool-arena? state))
    (compiler-driver-state-session-cache-enabled? state))
    unit
    (intern-persistent-arena-reset!)))

(define (compiler-driver-state-install-builtins! [state : CompilerDriverState]) : unit
  (begin
    (cbi.state-install! (array-ref (struct-get state builtin-ids) 0))
    ;; Force the generation-guarded refresh so every compiler-builtin-id-* global
    ;; is valid before any phase (lex/parse/load/typecheck) reads one. state-install
    ;; restored the prior compile's ids and generation, but a reset intern table
    ;; makes those stale until refresh re-interns against the current table.
    (cbi.compiler-builtin-refresh!)))

(define (compiler-driver-state-install-lower-arenas!
  [state : CompilerDriverState]) : unit
  (compiler-lower-arena-state-install!
    (array-ref (struct-get state lower-arenas) 0)))

(define (compiler-driver-state-capture-active-pools!
  [state : CompilerDriverState]) : unit
  (begin
    (array-set! (struct-get state expr-pool) 0 (ast-node-pool-state-capture))
    (array-set! (struct-get state type-pool) 0 (ty-node-pool-state-capture))))

(define (compiler-driver-state-capture-active-interns!
  [state : CompilerDriverState]) : unit
  (ci.intern-compat-state-capture-from-globals!
    (array-ref (struct-get state intern-state) 0)))

(define (compiler-driver-state-intern-generation [state : CompilerDriverState]) : i64
  (ci.intern-compat-state-generation
    (array-ref (struct-get state intern-state) 0)))

(define (compiler-driver-state-intern-pool-len [state : CompilerDriverState]) : i64
  (ci.intern-compat-state-pool-len
    (array-ref (struct-get state intern-state) 0)))

(define (compiler-driver-state-intern-pool-data-addr
  [state : CompilerDriverState]) : i64
  (ci.intern-compat-state-pool-data-addr
    (array-ref (struct-get state intern-state) 0)))

(define (compiler-driver-state-capture-active-builtins!
  [state : CompilerDriverState]) : unit
  (cbi.state-capture-from-globals! (array-ref (struct-get state builtin-ids) 0)))

(define (compiler-driver-state-builtin-generation [state : CompilerDriverState]) : i64
  (cbi.state-generation (array-ref (struct-get state builtin-ids) 0)))

(define (compiler-driver-state-builtin-ids-data-addr
  [state : CompilerDriverState]) : i64
  (cbi.state-ids-data-addr (array-ref (struct-get state builtin-ids) 0)))

(define (compiler-driver-state-reset-builtins! [state : CompilerDriverState]) : unit
  (begin
    (cbi.state-reset! (array-ref (struct-get state builtin-ids) 0))
    (compiler-driver-state-install-builtins! state)))

(define (compiler-driver-builtin-typecheck-string-length-id? [name-id : i64]) : bool
  (cbi.compiler-builtin-typecheck-string-length-id? name-id))

(define (compiler-driver-builtin-typecheck-array-length-id? [name-id : i64]) : bool
  (cbi.compiler-builtin-typecheck-array-length-id? name-id))

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
    (compiler-driver-state-capture-active-interns! state)
    (compiler-driver-state-capture-active-transients! state)
    (compiler-load-session-state-use! (struct-get state load-session))))

(define (compiler-driver-lowered-from-active-pools
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]) : ResultCompilerDriverLowered
  (ResultCompilerDriverLowered.Ok
    program
    spans
    (ast-node-pool-context-capture-active)))

(define (compiler-driver-lowered-from-pools
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [pools : AstNodePoolContext]) : ResultCompilerDriverLowered
  (ResultCompilerDriverLowered.Ok
    program
    spans
    (ast-node-pool-context-snapshot pools)))

(define (compiler-driver-install-lowered-pools! [pools : AstNodePoolContext]) : unit
  (ast-node-pool-context-install! pools))

(define (compiler-driver-runtime-prelude-cache-lookup [key : String]) : CompilerLoadPreludeCacheLookup
  (compiler-load-runtime-prelude-cache-lookup key))

(define (compiler-driver-runtime-prelude-cache-store
  [key : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]) : unit
  (compiler-load-runtime-prelude-cache-store key decls paths modules seen))

(define (compiler-driver-runtime-prelude-cache-store-with-pools
  [key : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]
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
    (compiler-typecheck-reset-intern-owned-state!)
    (cbi.compiler-builtin-reset!)
    (ctfe-builtin-reset!)
    (compiler-typecheck-reset-file-state!)
    (lower-reset-file-state!)
    ;; Drop the previous entry's lowerer arenas. At opt level 0
    ;; the escaped IR stays alive until the next file reset.
    (lower-arenas-release!)))

(define (compiler-driver-reset-analysis-state!) : unit
  (begin
    (cbi.compiler-builtin-reset!)
    (ctfe-builtin-reset!)
    (compiler-typecheck-reset-file-state!)
    (lower-reset-file-state!)
    (lower-arenas-release!)))

(define (compiler-driver-state-reset-file-state! [state : CompilerDriverState]) : unit
  (begin
    (compiler-driver-state-apply-session-flags! state)
    (compiler-driver-state-reset-owned-pool-arena-if-uncached! state)
    (let
      [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
      (begin
        (compiler-load-session-reset-pools-with-pools! pools)
        (compiler-driver-state-install-pools! state)
        (compiler-driver-state-install-interns! state)
        (compiler-load-session-reset-interns!)
        (compiler-typecheck-reset-intern-owned-state!)
        (compiler-driver-state-install-transients! state)
        (compiler-driver-state-reset-builtins! state)
        (ctfe-builtin-reset!)
        (compiler-typecheck-reset-file-state!)
        (compiler-driver-state-reset-owned-intern-arena-if-uncached! state)
        (lower-reset-file-state!)
        ;; Drop the previous entry's lowerer arenas. At opt level 0
        ;; the escaped IR stays alive until the next file reset.
        (lower-arenas-release!)
        (compiler-driver-state-capture-active-interns! state)
        (compiler-driver-state-capture-active-transients! state)))))

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
    (string.append "|" (string.int->string value))))

(cfg
  compile-profile
  (define (compiler-driver-profile-line
    [phase : String]
    [elapsed-ms : i64]
    [alloc-delta : i64]
    [live-delta : i64]
    [peak-delta : i64]) : String
    (string.append
      "compile-profile|"
      (string.append
        phase
        (string.append
          (compiler-driver-profile-field elapsed-ms)
          (string.append
            (compiler-driver-profile-field alloc-delta)
            (string.append
              (compiler-driver-profile-field live-delta)
              (string.append (compiler-driver-profile-field peak-delta) "\n"))))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-phase) : unit
    (begin
      (set! compiler-driver-profile-phase-start-ms (profile.now-ms))
      (set! compiler-driver-profile-phase-start-total (profile.alloc-total))
      (set! compiler-driver-profile-phase-start-live (profile.alloc-live))
      (profile.alloc-reset-peak))))

(cfg
  compile-profile
  (define (compiler-driver-profile-finish-phase [phase : String]) : unit
    (let
      [end-ms : i64 (profile.now-ms)]
      [end-total : i64 (profile.alloc-total)]
      [end-live : i64 (profile.alloc-live)]
      [peak-delta : i64
        (compiler-driver-profile-nonnegative
          (- (profile.alloc-peak) compiler-driver-profile-phase-start-live))]
      (begin
        (set!
          compiler-driver-profile-best-peak
          (compiler-driver-profile-max
            compiler-driver-profile-best-peak
            peak-delta))
        (io.print-error
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
      (set! compiler-driver-profile-total-start-ms (profile.now-ms))
      (set! compiler-driver-profile-total-start-total (profile.alloc-total))
      (set! compiler-driver-profile-total-start-live (profile.alloc-live))
      (set! compiler-driver-profile-best-peak 0)
      (ci.intern-profile-reset!)
      (io.print-error
        "compile-profile|phase|elapsed_ms|alloc_delta_bytes|live_delta_bytes|peak_live_delta_bytes\n")
      (compiler-driver-profile-start-phase))))

(cfg
  compile-profile
  (define (compiler-driver-profile-intern-line [name : String] [value : i64]) : unit
    (io.print-error
      (string.append
        "compile-profile|intern."
        (string.append
          name
          (string.append (compiler-driver-profile-field value) "|0|0|0\n"))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-finish-total) : unit
    (begin
      (io.print-error
        (compiler-driver-profile-line
          "total"
          (- (profile.now-ms) compiler-driver-profile-total-start-ms)
          (- (profile.alloc-total) compiler-driver-profile-total-start-total)
          (- (profile.alloc-live) compiler-driver-profile-total-start-live)
          compiler-driver-profile-best-peak))
      (compiler-driver-profile-intern-line
        "hash_words"
        (ci.intern-profile-hash-words-value))
      (compiler-driver-profile-intern-line
        "intern_calls"
        (ci.intern-profile-intern-value))
      (compiler-driver-profile-intern-line
        "slice_calls"
        (ci.intern-profile-slice-value))
      (compiler-driver-profile-intern-line
        "lookup_calls"
        (ci.intern-profile-lookup-value))
      (compiler-driver-profile-intern-line
        "hit_same_obj"
        (ci.intern-profile-hit-same-obj-value))
      (compiler-driver-profile-intern-line
        "hit_diff_obj"
        (ci.intern-profile-hit-diff-obj-value))
      (compiler-driver-profile-intern-line
        "miss"
        (ci.intern-profile-miss-value))
      (compiler-driver-profile-intern-line
        "tc_name_id_calls"
        (tc-name-id-call-value))
      (compiler-driver-profile-intern-line
        "attrib_bind_raw"
        (tc-attrib-bind-raw-value))
      (compiler-driver-profile-intern-line
        "attrib_lookup"
        (tc-attrib-lookup-value))
      (compiler-driver-profile-intern-line
        "attrib_lookup_unsafe"
        (tc-attrib-lookup-unsafe-value))
      (compiler-driver-profile-intern-line
        "attrib_binding_unsafe"
        (tc-attrib-binding-unsafe-value))
      (compiler-driver-profile-intern-line
        "attrib_marker_miss"
        (tc-attrib-marker-miss-value))
      (compiler-driver-profile-intern-line
        "attrib_slash_qualified"
        (tc-attrib-source-name-bound-exact-value))
      (compiler-driver-profile-intern-line
        "attrib_name_bound_exact"
        (tc-attrib-lookup-visible-id-value))
      (compiler-driver-profile-intern-line
        "attrib_local_bound_before_mod"
        (tc-attrib-stdlib-comptime-syntax-type-value))
      (compiler-driver-profile-intern-line
        "attrib_default_unshadowed"
        (tc-attrib-dotted-type-name-lookup-key-value)))))

(define (compiler-driver-lower-mode-for-target
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]) : CompilerLowerMode
  (match mode
    [(CompilerBackendMode.Avx2)
      (match target
        [(CompilerBackendTarget.Linux) (CompilerLowerMode.LinuxAvx2)]
        [(CompilerBackendTarget.Windows) (CompilerLowerMode.WindowsAvx2)])]
    [(CompilerBackendMode.Avx512)
      (match target
        [(CompilerBackendTarget.Linux) (CompilerLowerMode.LinuxAvx512)]
        [(CompilerBackendTarget.Windows) (CompilerLowerMode.WindowsAvx512)])]
    [_
      (match target
        [(CompilerBackendTarget.Linux) (CompilerLowerMode.LinuxScalar)]
        [(CompilerBackendTarget.Windows) (CompilerLowerMode.WindowsScalar)])]))

(define (compiler-driver-enable-linux-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-cfg-enable
    (compiler-cfg-enable
      (compiler-cfg-enable (compiler-cfg-enable cfgs "linux") "unix")
      "target-linux")
    "os-linux"))

(define (compiler-driver-enable-windows-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-cfg-enable
    (compiler-cfg-enable (compiler-cfg-enable cfgs "windows") "target-windows")
    "os-windows"))

(define (compiler-driver-enable-language-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-cfg-enable
    (compiler-cfg-enable
      (compiler-cfg-enable
        (compiler-cfg-enable
          (compiler-cfg-enable
            (compiler-cfg-enable
              (compiler-cfg-enable
                (compiler-cfg-enable
                  (compiler-cfg-enable cfgs "feature-ptr-addr-of")
                  "feature-str-view")
                "feature-runtime-str-view-extern")
              "feature-private-string-intrinsics")
            "feature-compiler-private-string-intrinsics")
          "array-helper-intrinsics")
        "feature-tl-memchr")
      "feature-plain-comptime-well-known")
    "feature-comptime-public-fields"))

(define (compiler-driver-target-cfgs
  [target : CompilerBackendTarget]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-driver-enable-language-cfgs
    (match target
      [(CompilerBackendTarget.Linux) (compiler-driver-enable-linux-cfgs cfgs)]
      [(CompilerBackendTarget.Windows)
        (compiler-driver-enable-windows-cfgs cfgs)])))

(define (compiler-driver-state-target-cfgs
  [state : CompilerDriverState]
  [target : CompilerBackendTarget]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (begin
    (compiler-driver-state-install-interns! state)
    (let
      [target-cfgs : sym_i64_env.SymI64Env
        (compiler-driver-target-cfgs target cfgs)]
      (begin
        (compiler-driver-state-capture-active-interns! state)
        target-cfgs))))

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
    (CompilerBackendMode.Scalar)
    opt-level
    emit-entry))

;; The lowered IR functions live in a dedicated arena
;; (lower-ir-arena); at opt levels >= 1 the optimizer deep-clones every
;; surviving function out of it, so the arena is dead weight (~172MB on a
;; cli.tl self-compile) once optimization returns. At level 0 the lowered
;; program flows to the backend unchanged and the arena must stay alive.
(define (compiler-driver-release-lowered-ir! [opt-level : i64]) : unit
  (if (>= opt-level 1)
    (lower-ir-arena-release!)
    unit))

;; Once lowering has produced IR, optimizer/backend no longer consult the
;; typecheck/macro CTFE caches. Drop them before the backend's large assembly
;; buffers are allocated so self-compiles do not carry dead layout metadata and
;; macro/typecheck scratch state through codegen. The lower scratch arena is also
;; function-local: escaped IR lives outside it, so it can be released before
;; optimize/backend instead of overlapping with backend assembly buffers.
(define (compiler-driver-release-typecheck-caches-after-lower!) : unit
  (begin
    (compiler-typecheck-reset-file-state!)
    (lower-scratch-arena-release!)))

;; Package builds may run TLci, direct-object, and doctest passes after an
;; assembly emit while keeping the loaded AST alive. A full file-state reset
;; would invalidate those loaded pools, but the lowered IR has already been
;; consumed by the backend and can be dropped at any opt level.
(define (compiler-driver-release-lower-arenas-after-emit!) : unit
  (lower-arenas-release!))

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
  (if (ast-node-pool-reader-type-exhausted?)
    (ResultCompilerDriver.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (cfg compile-profile (compiler-driver-profile-start-phase))
      (match (optimize-program-with-spans-and-level program spans opt-level)
        [(CompilerOptimizedProgram.Program optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-reader-type-exhausted?)
              (ResultCompilerDriver.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
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
                    (CompilerBackendTarget.Linux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry))
                  [(ResultCompilerBackend.Ok asm)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ResultCompilerDriver.Ok asm))]
                  [(ResultCompilerBackend.Err diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ResultCompilerDriver.Err
                        (box
                          (compiler-diagnostic-with-path
                            (box-get diag)
                            input-path))))]))))]))))

(define (compiler-driver-emit-lowered-buffer-with-level-mode-and-entry
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]) : ResultCompilerDriverBuffer
  (compiler-driver-emit-lowered-buffer-with-level-mode-entry-and-crt
    input-path
    program
    spans
    target
    has-target
    mode
    opt-level
    emit-entry
    false))

(define (compiler-driver-emit-lowered-buffer-with-level-mode-entry-and-crt
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverBuffer
  (if (ast-node-pool-reader-type-exhausted?)
    (ResultCompilerDriverBuffer.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (cfg compile-profile (compiler-driver-profile-start-phase))
      (match (optimize-program-with-spans-and-level program spans opt-level)
        [(CompilerOptimizedProgram.Program optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-reader-type-exhausted?)
              (ResultCompilerDriverBuffer.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
              (begin
                (compiler-backend-set-scalar-registers! (>= opt-level 2))
                (cfg compile-profile (compiler-driver-profile-start-phase))
                (match (if has-target
                  (compiler-backend-emit-program-target-with-mode-final-buffer-and-crt
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry)
                  (compiler-backend-emit-program-target-with-mode-final-buffer-and-crt
                    optimized
                    (CompilerBackendTarget.Linux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry))
                  [(ResultCompilerBackendBuffer.Ok asm)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ResultCompilerDriverBuffer.Ok asm))]
                  [(ResultCompilerBackendBuffer.Err diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ResultCompilerDriverBuffer.Err
                        (box
                          (compiler-diagnostic-with-path
                            (box-get diag)
                            input-path))))]))))]))))

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
  (if (ast-node-pool-reader-type-exhausted?)
    (ResultCompilerDriverObject.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (cfg compile-profile (compiler-driver-profile-start-phase))
      (match (optimize-program-with-spans-and-level program spans opt-level)
        [(CompilerOptimizedProgram.Program optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-reader-type-exhausted?)
              (ResultCompilerDriverObject.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
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
                    (CompilerBackendTarget.Linux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry))
                  [(ResultCompilerBackendObject.Ok image)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ResultCompilerDriverObject.Ok image))]
                  [(ResultCompilerBackendObject.Err diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ResultCompilerDriverObject.Err
                        (box
                          (compiler-diagnostic-with-path
                            (box-get diag)
                            input-path))))]))))]))))

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
  (if (ast-node-pool-reader-type-exhausted?)
    (ResultCompilerDriverPic.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (cfg compile-profile (compiler-driver-profile-start-phase))
      (match (optimize-program-with-spans-and-level program spans opt-level)
        [(CompilerOptimizedProgram.Program optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-reader-type-exhausted?)
              (ResultCompilerDriverPic.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
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
                    (CompilerBackendTarget.Linux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry))
                  [(ResultCompilerBackendPic.Ok output)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ResultCompilerDriverPic.Ok output))]
                  [(ResultCompilerBackendPic.Err diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase "backend"))
                      (ResultCompilerDriverPic.Err
                        (box
                          (compiler-diagnostic-with-path
                            (box-get diag)
                            input-path))))]))))]))))

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
    [(ResultCompilerDriverLowered.Ok program spans pools)
      (let
        [out : ResultCompilerDriver
          (begin
            (ast-node-pool-reader-use! pools)
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
        (begin
          (ast-node-pool-reader-clear!)
          out))]
    [(ResultCompilerDriverLowered.Err diag) (ResultCompilerDriver.Err diag)]))

(define (compiler-driver-emit-lowered-result-buffer-with-level-mode-and-entry
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]) : ResultCompilerDriverBuffer
  (match lowered
    [(ResultCompilerDriverLowered.Ok program spans pools)
      (let
        [out : ResultCompilerDriverBuffer
          (begin
            (ast-node-pool-reader-use! pools)
            (compiler-driver-emit-lowered-buffer-with-level-mode-and-entry
              input-path
              program
              spans
              target
              has-target
              mode
              opt-level
              emit-entry))]
        (begin
          (ast-node-pool-reader-clear!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (ResultCompilerDriverBuffer.Err diag)]))

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
    [(ResultCompilerDriverLowered.Ok program spans pools)
      (let
        [out : ResultCompilerDriverObject
          (begin
            (ast-node-pool-reader-use! pools)
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
        (begin
          (ast-node-pool-reader-clear!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (ResultCompilerDriverObject.Err diag)]))

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
    [(ResultCompilerDriverLowered.Ok program spans pools)
      (let
        [out : ResultCompilerDriverPic
          (begin
            (ast-node-pool-reader-use! pools)
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
        (begin
          (ast-node-pool-reader-clear!)
          out))]
    [(ResultCompilerDriverLowered.Err diag) (ResultCompilerDriverPic.Err diag)]))

;; The implicit prelude prepended before every entry program. It is two
;; always-linked stdlib modules loaded as files:
;;   - stdlib/runtime.tl  - fault/abort handlers + OS primitives,
;;     exported as fixed symbols; kept as reachability roots.
;;   - stdlib/core_macros.tl - the implicit core macro prelude: `and`,
;;     `or`, `when`, `unless`, `cond`. Loaded right after runtime so its macros
;;     are source-order visible to the entry and resolve as bare unqualified
;;     calls via the prelude fallback in `macro-call-decl`.
;; Loading the prelude first lets the entry's own (possibly transitive) imports
;; dedup against it before the decls/paths/modules are concatenated.
(define (compiler-driver-load-runtime-prelude-cold
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-file-with-paths-and-roots-cfg
    "stdlib/runtime.tl"
    (sym_i64_env.sym-i64-empty)
    stdlib-roots
    cfgs)
    [(ResultCompilerLoadWithPaths.Ok
        runtime-decls
        runtime-paths
        runtime-modules
        runtime-seen)
      (match (compiler-load-core-macro-prelude-with-roots-cfg
        runtime-seen
        stdlib-roots
        cfgs)
        [(ResultCompilerLoadWithPaths.Ok
            macro-decls
            macro-paths
            macro-modules
            macro-seen)
          (ResultCompilerLoadWithPaths.Ok
            (compiler-load-decl-list-append runtime-decls macro-decls)
            (compiler-load-decl-path-list-append runtime-paths macro-paths)
            (compiler-load-decl-module-list-append
              runtime-modules
              macro-modules)
            macro-seen)]
        [(ResultCompilerLoadWithPaths.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-runtime-prelude-cache-miss
  [key : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [prev-arena : i64 (arena.tl_arena_current)]
    [loaded : ResultCompilerLoadWithPaths
      (begin
        (unsafe
          (arena.tl_arena_set node-pool-base-arena))
        (let
          [persistent-key : String (string.copy (& key))]
          [cold : ResultCompilerLoadWithPaths
            (compiler-driver-load-runtime-prelude-cold stdlib-roots cfgs)]
          (begin
            (match cold
              [(ResultCompilerLoadWithPaths.Ok decls paths modules seen)
                (compiler-driver-runtime-prelude-cache-store
                  persistent-key
                  decls
                  paths
                  modules
                  seen)]
              [(ResultCompilerLoadWithPaths.Err _) unit])
            (unsafe
              (arena.tl_arena_set prev-arena))
            cold)))]
    loaded))

(define (compiler-driver-load-runtime-prelude
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (if (compiler-load-session-cache-enabled?)
    (let
      [key : String
        (compiler-load-prelude-cache-key "runtime-prelude" stdlib-roots cfgs)]
      (match (compiler-driver-runtime-prelude-cache-lookup key)
        [(CompilerLoadPreludeCacheHit decls paths modules seen)
          (ResultCompilerLoadWithPaths.Ok decls paths modules seen)]
        [(CompilerLoadPreludeCacheMiss)
          (compiler-driver-load-runtime-prelude-cache-miss
            key
            stdlib-roots
            cfgs)]))
    (compiler-driver-load-runtime-prelude-cold stdlib-roots cfgs)))

(define (compiler-driver-load-file-with-runtime
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  ;; Prepend the implicit prelude (runtime + core macros), then load the entry.
  (match (compiler-driver-load-runtime-prelude stdlib-roots cfgs)
    [(ResultCompilerLoadWithPaths.Ok
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler-load-entry-file-with-paths-and-roots-cfg
        input-path
        prelude-seen
        stdlib-roots
        cfgs)
        [(ResultCompilerLoadWithPaths.Ok
            entry-decls
            entry-paths
            entry-modules
            seen)
          (ResultCompilerLoadWithPaths.Ok
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ResultCompilerLoadWithPaths.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-source-with-runtime
  [input-path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-driver-load-runtime-prelude stdlib-roots cfgs)
    [(ResultCompilerLoadWithPaths.Ok
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
        [(ResultCompilerLoadWithPaths.Ok
            entry-decls
            entry-paths
            entry-modules
            seen)
          (ResultCompilerLoadWithPaths.Ok
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ResultCompilerLoadWithPaths.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-file-for-pic-image
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-core-macro-prelude-with-roots-cfg
    (sym_i64_env.sym-i64-empty)
    stdlib-roots
    cfgs)
    [(ResultCompilerLoadWithPaths.Ok
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler-load-entry-file-with-paths-and-roots-cfg
        input-path
        prelude-seen
        stdlib-roots
        cfgs)
        [(ResultCompilerLoadWithPaths.Ok
            entry-decls
            entry-paths
            entry-modules
            seen)
          (ResultCompilerLoadWithPaths.Ok
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ResultCompilerLoadWithPaths.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-runtime-prelude-cold-with-pools
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-load-file-with-paths-and-roots-cfg-with-pools
    "stdlib/runtime.tl"
    (sym_i64_env.sym-i64-empty)
    stdlib-roots
    cfgs
    pools)
    [(ResultCompilerLoadWithPaths.Ok
        runtime-decls
        runtime-paths
        runtime-modules
        runtime-seen)
      (match (compiler-load-core-macro-prelude-with-roots-cfg-with-pools
        runtime-seen
        stdlib-roots
        cfgs
        pools)
        [(ResultCompilerLoadWithPaths.Ok
            macro-decls
            macro-paths
            macro-modules
            macro-seen)
          (ResultCompilerLoadWithPaths.Ok
            (compiler-load-decl-list-append runtime-decls macro-decls)
            (compiler-load-decl-path-list-append runtime-paths macro-paths)
            (compiler-load-decl-module-list-append
              runtime-modules
              macro-modules)
            macro-seen)]
        [(ResultCompilerLoadWithPaths.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-runtime-prelude-cache-miss-with-pools
  [key : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (let
    [prev-arena : i64 (arena.tl_arena_current)]
    [loaded : ResultCompilerLoadWithPaths
      (begin
        (unsafe
          (arena.tl_arena_set (ast-node-pool-context-base-arena pools)))
        (let
          [persistent-key : String (string.copy (& key))]
          [cold : ResultCompilerLoadWithPaths
            (compiler-driver-load-runtime-prelude-cold-with-pools
              stdlib-roots
              cfgs
              pools)]
          (begin
            (match cold
              [(ResultCompilerLoadWithPaths.Ok decls paths modules seen)
                (compiler-driver-runtime-prelude-cache-store-with-pools
                  persistent-key
                  decls
                  paths
                  modules
                  seen
                  pools)]
              [(ResultCompilerLoadWithPaths.Err _) unit])
            (unsafe
              (arena.tl_arena_set prev-arena))
            cold)))]
    loaded))

(define (compiler-driver-load-runtime-prelude-with-pools
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (if (compiler-load-session-cache-enabled?)
    (let
      [key : String
        (compiler-load-prelude-cache-key "runtime-prelude" stdlib-roots cfgs)]
      (match (compiler-driver-runtime-prelude-cache-lookup key)
        [(CompilerLoadPreludeCacheHit decls paths modules seen)
          (ResultCompilerLoadWithPaths.Ok decls paths modules seen)]
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
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-driver-load-runtime-prelude-with-pools
    stdlib-roots
    cfgs
    pools)
    [(ResultCompilerLoadWithPaths.Ok
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
        [(ResultCompilerLoadWithPaths.Ok
            entry-decls
            entry-paths
            entry-modules
            seen)
          (ResultCompilerLoadWithPaths.Ok
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ResultCompilerLoadWithPaths.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-source-with-runtime-with-pools
  [input-path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-driver-load-runtime-prelude-with-pools
    stdlib-roots
    cfgs
    pools)
    [(ResultCompilerLoadWithPaths.Ok
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
        input-path
        source
        prelude-seen
        stdlib-roots
        AstMaybeModuleName.No
        cfgs
        pools)
        [(ResultCompilerLoadWithPaths.Ok
            entry-decls
            entry-paths
            entry-modules
            seen)
          (ResultCompilerLoadWithPaths.Ok
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ResultCompilerLoadWithPaths.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-file-for-pic-image-with-pools
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-load-core-macro-prelude-with-roots-cfg-with-pools
    (sym_i64_env.sym-i64-empty)
    stdlib-roots
    cfgs
    pools)
    [(ResultCompilerLoadWithPaths.Ok
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
        [(ResultCompilerLoadWithPaths.Ok
            entry-decls
            entry-paths
            entry-modules
            seen)
          (ResultCompilerLoadWithPaths.Ok
            (compiler-load-decl-list-append prelude-decls entry-decls)
            (compiler-load-decl-path-list-append prelude-paths entry-paths)
            (compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(ResultCompilerLoadWithPaths.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-and-lower-escaping
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverLowered
  (match (compiler-driver-load-file-with-runtime input-path stdlib-roots cfgs)
    [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
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
          [(ResultCompilerLower.Ok program spans)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase "lower"))
              (if (ast-node-pool-reader-type-exhausted?)
                (ResultCompilerDriverLowered.Err
                  (box
                    (compiler-driver-ty-node-pool-exhausted-diagnostic
                      input-path)))
                (compiler-driver-lowered-from-active-pools program spans)))]
          [(ResultCompilerLower.Err diag)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase "lower"))
              (ResultCompilerDriverLowered.Err diag))]))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
        (ResultCompilerDriverLowered.Err diag))]))

(define (compiler-driver-load-and-lower-pic-image
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverLowered
  (match (compiler-driver-load-file-for-pic-image input-path stdlib-roots cfgs)
    [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
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
          [(ResultCompilerLower.Ok program spans)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase "lower"))
              (if (ast-node-pool-reader-type-exhausted?)
                (ResultCompilerDriverLowered.Err
                  (box
                    (compiler-driver-ty-node-pool-exhausted-diagnostic
                      input-path)))
                (compiler-driver-lowered-from-active-pools program spans)))]
          [(ResultCompilerLower.Err diag)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase "lower"))
              (ResultCompilerDriverLowered.Err diag))]))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
        (ResultCompilerDriverLowered.Err diag))]))

(define (compiler-driver-load-and-lower-escaping-with-state
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverLowered
  (let
    [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
    [_install-interns : unit (compiler-driver-state-install-interns! state)]
    [_reset-type-literal-tracking : unit
      (compiler-parse-type-literal-tracking-reset!)]
    (match (compiler-driver-load-file-with-runtime-with-pools
      input-path
      stdlib-roots
      cfgs
      pools)
      [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
        (begin
          (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
          (cfg compile-profile (compiler-driver-profile-start-phase))
          (compiler-driver-state-install-transients! state)
          (compiler-driver-state-install-pools! state)
          (let
            [release-source-pools? : bool
              (compiler-driver-state-can-release-checked-lower-source-pools?
                state)]
            [defer-source-destroy? : bool
              (and
                release-source-pools?
                (compiler-parse-current-load-has-type-literal?))]
            [dest-pools : AstNodePoolContext
              (if release-source-pools?
                (compiler-driver-state-new-checked-lower-pools)
                pools)]
            [entry-arena : i64 (arena.tl_arena_current)]
            ;; Release the source pools from the newest segment of their arena
            ;; chain, not the make() root handle: the chain is reachable only from
            ;; its head, so destroying the root leaks every overflow segment (the
            ;; whole-program parsed AST), which accumulates across batch entries.
            [source-pools-arena : i64 (compiler-driver-node-pool-base-arena)]
            [_clear-source-floors : unit
              (if release-source-pools?
                (compiler-load-session-floors-set! 0 0 0)
                unit)]
            [_arm-release : unit
              (if release-source-pools?
                (compiler-lower-checked-dest-pools-use!
                  dest-pools
                  (if defer-source-destroy?
                    0
                    source-pools-arena))
                (compiler-lower-checked-dest-pools-clear!))]
            [lowered : ResultCompilerLower
              (lower-compiler-program-with-decl-paths-mode-cache-and-pools
                input-path
                (ast-program decls)
                paths
                (compiler-driver-lower-mode-for-target target mode)
                stdlib-roots
                (compiler-load-prelude-cache-key
                  "typecheck-prefix-lower"
                  stdlib-roots
                  cfgs)
                pools)]
            [dest-committed? : bool
              (compiler-lower-checked-dest-pools-committed?)]
            [result-pools : AstNodePoolContext
              (if dest-committed?
                (compiler-lower-checked-dest-pools-current)
                pools)]
            [_adopt-dest : unit
              (if dest-committed?
                (compiler-driver-state-adopt-pools! state result-pools)
                unit)]
            [_destroy-unused-dest : unit
              (if (and release-source-pools? (not dest-committed?))
                (compiler-driver-state-destroy-uncommitted-pools! dest-pools)
                unit)]
            [_destroy-deferred-source : unit
              (if (and defer-source-destroy? dest-committed?)
                (begin
                  (compiler-typecheck-ctfe-env-cache-clear!)
                  (unsafe
                    (arena.tl_arena_destroy source-pools-arena)))
                unit)]
            [_restore-entry-arena : unit
              (if release-source-pools?
                (unsafe
                  (arena.tl_arena_set
                    (if (and dest-committed? (= entry-arena source-pools-arena))
                      (ast-node-pool-context-base-arena result-pools)
                      entry-arena)))
                unit)]
            [_clear-release : unit (compiler-lower-checked-dest-pools-clear!)]
            (match lowered
              [(ResultCompilerLower.Ok program spans)
                (begin
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase "lower"))
                  (if (ast-node-pool-reader-type-exhausted?)
                    (ResultCompilerDriverLowered.Err
                      (box
                        (compiler-driver-ty-node-pool-exhausted-diagnostic
                          input-path)))
                    (compiler-driver-lowered-from-pools
                      program
                      spans
                      result-pools)))]
              [(ResultCompilerLower.Err diag)
                (begin
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase "lower"))
                  (ResultCompilerDriverLowered.Err diag))])))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
          (ResultCompilerDriverLowered.Err diag))])))

(define (compiler-driver-load-and-lower-pic-image-with-state
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverLowered
  (let
    [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
    [_install-interns : unit (compiler-driver-state-install-interns! state)]
    [_reset-type-literal-tracking : unit
      (compiler-parse-type-literal-tracking-reset!)]
    (match (compiler-driver-load-file-for-pic-image-with-pools
      input-path
      stdlib-roots
      cfgs
      pools)
      [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
        (begin
          (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
          (cfg compile-profile (compiler-driver-profile-start-phase))
          (compiler-driver-state-install-transients! state)
          (compiler-driver-state-install-pools! state)
          (let
            [release-source-pools? : bool
              (compiler-driver-state-can-release-checked-lower-source-pools?
                state)]
            [defer-source-destroy? : bool
              (and
                release-source-pools?
                (compiler-parse-current-load-has-type-literal?))]
            [dest-pools : AstNodePoolContext
              (if release-source-pools?
                (compiler-driver-state-new-checked-lower-pools)
                pools)]
            [entry-arena : i64 (arena.tl_arena_current)]
            ;; Release the source pools from the newest segment of their arena
            ;; chain, not the make() root handle: the chain is reachable only from
            ;; its head, so destroying the root leaks every overflow segment (the
            ;; whole-program parsed AST), which accumulates across batch entries.
            [source-pools-arena : i64 (compiler-driver-node-pool-base-arena)]
            [_clear-source-floors : unit
              (if release-source-pools?
                (compiler-load-session-floors-set! 0 0 0)
                unit)]
            [_arm-release : unit
              (if release-source-pools?
                (compiler-lower-checked-dest-pools-use!
                  dest-pools
                  (if defer-source-destroy?
                    0
                    source-pools-arena))
                (compiler-lower-checked-dest-pools-clear!))]
            [lowered : ResultCompilerLower
              (lower-compiler-program-with-decl-paths-mode-cache-and-pools
                input-path
                (ast-program decls)
                paths
                (compiler-driver-lower-mode-for-target target mode)
                stdlib-roots
                (compiler-load-prelude-cache-key
                  "typecheck-prefix-lower"
                  stdlib-roots
                  cfgs)
                pools)]
            [dest-committed? : bool
              (compiler-lower-checked-dest-pools-committed?)]
            [result-pools : AstNodePoolContext
              (if dest-committed?
                (compiler-lower-checked-dest-pools-current)
                pools)]
            [_adopt-dest : unit
              (if dest-committed?
                (compiler-driver-state-adopt-pools! state result-pools)
                unit)]
            [_destroy-unused-dest : unit
              (if (and release-source-pools? (not dest-committed?))
                (compiler-driver-state-destroy-uncommitted-pools! dest-pools)
                unit)]
            [_destroy-deferred-source : unit
              (if (and defer-source-destroy? dest-committed?)
                (begin
                  (compiler-typecheck-ctfe-env-cache-clear!)
                  (unsafe
                    (arena.tl_arena_destroy source-pools-arena)))
                unit)]
            [_restore-entry-arena : unit
              (if release-source-pools?
                (unsafe
                  (arena.tl_arena_set
                    (if (and dest-committed? (= entry-arena source-pools-arena))
                      (ast-node-pool-context-base-arena result-pools)
                      entry-arena)))
                unit)]
            [_clear-release : unit (compiler-lower-checked-dest-pools-clear!)]
            (match lowered
              [(ResultCompilerLower.Ok program spans)
                (begin
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase "lower"))
                  (if (ast-node-pool-reader-type-exhausted?)
                    (ResultCompilerDriverLowered.Err
                      (box
                        (compiler-driver-ty-node-pool-exhausted-diagnostic
                          input-path)))
                    (compiler-driver-lowered-from-pools
                      program
                      spans
                      result-pools)))]
              [(ResultCompilerLower.Err diag)
                (begin
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase "lower"))
                  (ResultCompilerDriverLowered.Err diag))])))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
          (ResultCompilerDriverLowered.Err diag))])))

(define (compiler-driver-emit-file-with-target
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    target
    has-target
    (svec.new)))

(define (compiler-driver-emit-file-with-target-and-roots
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]) : ResultCompilerDriver
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
  [stdlib-roots : svec.Vec]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-level-and-mode
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    (CompilerBackendMode.Scalar)))

(define (compiler-driver-emit-file-with-target-roots-level-and-mode
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
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
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriver
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
  [stdlib-roots : svec.Vec]
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
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [crt-entry : bool]) : ResultCompilerDriver
  (begin
    (cfg compile-profile (compiler-driver-profile-start-total))
    ;; The lowering provenance side table is remapped after
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
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverBuffer
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
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
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
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverPic
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
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverBuffer
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
        (compiler-driver-state-target-cfgs state target cfgs))
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
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverPic
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
        (compiler-driver-state-target-cfgs state target cfgs))
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
  [stdlib-roots : svec.Vec]
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
  [stdlib-roots : svec.Vec]
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
    (CompilerBackendMode.Scalar)
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
    [(ResultCompilerLower.Ok program spans)
      (compiler-driver-lowered-from-active-pools program spans)]
    [(ResultCompilerLower.Err diag) (ResultCompilerDriverLowered.Err diag)]))

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
  [stdlib-roots : svec.Vec]
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
    [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
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
        [(ResultCompilerLower.Ok program spans)
          (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
            input-path
            (compiler-driver-lowered-from-active-pools program spans)
            target
            has-target
            mode
            opt-level
            emit-entry
            crt-entry)]
        [(ResultCompilerLower.Err diag) (ResultCompilerDriver.Err diag)])]
    [(ResultCompilerLoadWithPaths.Err diag) (ResultCompilerDriver.Err diag)]))

(define (compiler-driver-load-package-file-with-runtime-cfg
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
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
  [stdlib-roots : svec.Vec]
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
  [stdlib-roots : svec.Vec]
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
    [(ResultCompilerLoadWithPaths.Ok decls paths modules seen)
      (ResultCompilerLoadWithPaths.Ok
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
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-package-file-with-runtime-owned-cfg
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-driver-load-package-file-with-runtime-cfg
    input-path
    stdlib-roots
    manifest-dir
    deps
    emit-entry
    cfgs)
    [(ResultCompilerLoadWithPaths.Ok decls paths modules seen)
      (ResultCompilerLoadWithPaths.Ok
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
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-ir-summary-line [name : String] [value : i64]) : String
  (string.append
    name
    (string.append " " (string.append (string.int->string value) "\n"))))

(define (compiler-driver-ir-summary-render [summary : CompilerIrSummary]) : String
  (let
    [out : String "typelisp-ir-summary v1\n"]
    (begin
      (set!
        out
        (string.concat3
          out
          (compiler-driver-ir-summary-line
            "globals"
            (compiler-ir-summary-globals summary))
          ""))
      (set!
        out
        (string.concat3
          out
          (compiler-driver-ir-summary-line
            "functions"
            (compiler-ir-summary-functions summary))
          ""))
      (set!
        out
        (string.concat3
          out
          (compiler-driver-ir-summary-line
            "externs"
            (compiler-ir-summary-externs summary))
          ""))
      (set!
        out
        (string.concat3
          out
          (compiler-driver-ir-summary-line
            "blocks"
            (compiler-ir-summary-blocks summary))
          ""))
      (set!
        out
        (string.concat3
          out
          (compiler-driver-ir-summary-line
            "instructions"
            (compiler-ir-summary-instructions summary))
          ""))
      (set!
        out
        (string.concat3
          out
          (compiler-driver-ir-summary-line
            "vars"
            (compiler-ir-summary-vars summary))
          ""))
      (set!
        out
        (string.concat3
          out
          (compiler-driver-ir-summary-line
            "empty-blocks"
            (compiler-ir-summary-empty-blocks summary))
          ""))
      (set!
        out
        (string.concat3
          out
          (compiler-driver-ir-summary-line
            "max-instructions-function"
            (compiler-ir-summary-max-instructions-function summary))
          ""))
      (set!
        out
        (string.concat3
          out
          (compiler-driver-ir-summary-line
            "max-instructions-block"
            (compiler-ir-summary-max-instructions-block summary))
          ""))
      (set!
        out
        (string.concat3
          out
          (compiler-driver-ir-summary-line
            "call-arg-entries"
            (compiler-ir-summary-call-arg-entries summary))
          ""))
      (set!
        out
        (string.concat3
          out
          (compiler-driver-ir-summary-line
            "phi-input-entries"
            (compiler-ir-summary-phi-input-entries summary))
          ""))
      (string.concat3
        out
        (compiler-driver-ir-summary-line
          "score"
          (compiler-ir-summary-score summary))
        ""))))

(define (compiler-driver-emit-ir-summary-lowered-with-level
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [opt-level : i64]) : ResultCompilerDriver
  (if (ast-node-pool-reader-type-exhausted?)
    (ResultCompilerDriver.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic "")))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (match (optimize-program-with-spans-and-level program spans opt-level)
        [(CompilerOptimizedProgram.Program optimized _)
          (begin
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-reader-type-exhausted?)
              (ResultCompilerDriver.Err
                (box (compiler-driver-ty-node-pool-exhausted-diagnostic "")))
              (ResultCompilerDriver.Ok
                (compiler-driver-ir-summary-render
                  (compiler-ir-program-summary optimized)))))]))))

(define (compiler-driver-emit-ir-summary-lowered-result-with-level
  [lowered : ResultCompilerDriverLowered]
  [opt-level : i64]) : ResultCompilerDriver
  (match lowered
    [(ResultCompilerDriverLowered.Ok program spans pools)
      (let
        [out : ResultCompilerDriver
          (begin
            (ast-node-pool-reader-use! pools)
            (compiler-driver-emit-ir-summary-lowered-with-level
              program
              spans
              opt-level))]
        (begin
          (ast-node-pool-reader-clear!)
          out))]
    [(ResultCompilerDriverLowered.Err diag) (ResultCompilerDriver.Err diag)]))

(define (compiler-driver-emit-ir-summary-file-with-roots-and-level
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-ir-summary-file-with-roots-level-and-cfg
    input-path
    stdlib-roots
    opt-level
    (compiler-cfg-empty)))

(define (compiler-driver-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriver
  ;; Emit-IR needs the macro prelude but must remain runtime-free so
  ;; target parity checks compare user IR rather than OS-specific runtime IR.
  (compiler-driver-emit-ir-summary-lowered-result-with-level
    (compiler-driver-load-and-lower-pic-image
      input-path
      target
      stdlib-roots
      mode
      (compiler-driver-target-cfgs target cfgs))
    opt-level))

(define (compiler-driver-state-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriver
  (compiler-driver-emit-ir-summary-lowered-result-with-level
    (compiler-driver-load-and-lower-pic-image-with-state
      state
      input-path
      target
      stdlib-roots
      mode
      (compiler-driver-state-target-cfgs state target cfgs))
    opt-level))

(define (compiler-driver-emit-ir-summary-file-with-roots-level-and-cfg
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriver
  (compiler-driver-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
    input-path
    (CompilerBackendTarget.Linux)
    stdlib-roots
    opt-level
    (CompilerBackendMode.Scalar)
    cfgs))

(define (compiler-driver-emit-file [input-path : String]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target
    input-path
    (CompilerBackendTarget.Linux)
    false))

(define (compiler-driver-emit-file-with-roots
  [input-path : String]
  [stdlib-roots : svec.Vec]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    (CompilerBackendTarget.Linux)
    false
    stdlib-roots))

(define (compiler-driver-emit-file-with-roots-and-level
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-and-level
    input-path
    (CompilerBackendTarget.Linux)
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
  [stdlib-roots : svec.Vec]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    target
    true
    stdlib-roots))

(define (compiler-driver-emit-file-for-target-with-roots-and-level
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-and-level
    input-path
    target
    true
    stdlib-roots
    opt-level))

(define (compiler-driver-write-text-buf
  [output-path : String]
  [buf : text_buf.TextBuf]) : i64
  (text_buf.write-file output-path buf))

(define (compiler-driver-write-result
  [result : ResultCompilerDriver]
  [output-path : String]) : i64
  (match result
    [(ResultCompilerDriver.Ok asm)
      (begin
        (cfg compile-profile (compiler-driver-profile-start-phase))
        (io.write-file output-path asm)
        (cfg compile-profile (compiler-driver-profile-finish-phase "write"))
        (cfg compile-profile (compiler-driver-profile-finish-total))
        (io.print-string
          (string.append "Wrote " (string.append output-path "\n")))
        0)]
    [(ResultCompilerDriver.Err diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-total))
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        1)]))

(define (compiler-driver-write-buffer-result
  [result : ResultCompilerDriverBuffer]
  [output-path : String]) : i64
  (match result
    [(ResultCompilerDriverBuffer.Ok buf)
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
              (io.print-string
                (string.append "Wrote " (string.append output-path "\n")))
              0)
            status)))]
    [(ResultCompilerDriverBuffer.Err diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-total))
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        1)]))

(define (compiler-driver-pic-fixups-path [output-path : String]) : String
  (string.append output-path ".fixups"))

(define (compiler-driver-write-pic-result
  [result : ResultCompilerDriverPic]
  [output-path : String]) : i64
  (match result
    [(ResultCompilerDriverPic.Ok output)
      (let
        [fixups-path : String (compiler-driver-pic-fixups-path output-path)]
        (begin
          (cfg compile-profile (compiler-driver-profile-start-phase))
          (io.write-file output-path (struct-get output asm))
          (io.write-file fixups-path (struct-get output fixups))
          (cfg compile-profile (compiler-driver-profile-finish-phase "write"))
          (cfg compile-profile (compiler-driver-profile-finish-total))
          (io.print-string
            (string.append "Wrote " (string.append output-path "\n")))
          (io.print-string
            (string.append "Wrote " (string.append fixups-path "\n")))
          0))]
    [(ResultCompilerDriverPic.Err diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-total))
        (io.print-error (compiler-diagnostic-render (box-get diag)))
        1)]))

(define (compiler-driver-compile-file-with-target-roots-level-mode-cfg
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : i64
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
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : i64
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
    (CompilerBackendTarget.Linux)
    false
    (svec.new)
    (compiler-optimize-default-level)
    (CompilerBackendMode.Scalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-with-roots
  [input-path : String]
  [output-path : String]
  [stdlib-roots : svec.Vec]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (CompilerBackendTarget.Linux)
    false
    stdlib-roots
    (compiler-optimize-default-level)
    (CompilerBackendMode.Scalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-with-roots-and-level
  [input-path : String]
  [output-path : String]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (CompilerBackendTarget.Linux)
    false
    stdlib-roots
    opt-level
    (CompilerBackendMode.Scalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-with-roots-level-and-mode
  [input-path : String]
  [output-path : String]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (CompilerBackendTarget.Linux)
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
    (svec.new)
    (compiler-optimize-default-level)
    (CompilerBackendMode.Scalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target-with-roots
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    stdlib-roots
    (compiler-optimize-default-level)
    (CompilerBackendMode.Scalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target-with-roots-and-level
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    stdlib-roots
    opt-level
    (CompilerBackendMode.Scalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target-with-roots-level-and-mode
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
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
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    stdlib-roots
    opt-level
    mode
    cfgs))