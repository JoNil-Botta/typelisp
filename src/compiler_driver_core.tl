;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.
(import stdlib.arena)
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)
(import (vector.vector String) as svec)
(cfg compile-profile (import stdlib.profile))
(import compiler_allocation_profile as allocation_profile)
(import compiler_profile_state as profile_state)
(import "compiler_backend.tl")
(import compiler_builtin_ids as cbi)
(import compiler_target_cfg_core as target_cfg)
(import "compiler_diagnostic.tl")
(import compiler_intern as ci)
(import "compiler_load.tl")
(cfg embedded-stdlib-tlci (import compiler_build_identity as build_identity))
(cfg embedded-stdlib-tlci (import "compiler_surface_hydrate.tl"))
(cfg
  compile-startup-profile
  (import compiler_startup_profile as startup_profile))
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
  (Ok
    CompilerIrProgram
    CompilerSourceSpans
    AstNodePoolContext
    profile_state.CompilerProfileState)
  (Err (Box CompilerDiagnostic)))

(define compiler-driver-pending-retired-source-arena : i64
  0)
(define compiler-driver-pending-retired-source-expr-storage-arena : i64
  0)
(define compiler-driver-pending-retired-source-type-storage-arena : i64
  0)

;; Uncached opt1/2 loads run parse/typecheck/list scratch in a separate arena.
;; Its surviving program shells escape at the same outer boundary as the
;; checked source arena, after every load/lower frame has returned.
(define compiler-driver-pending-retired-frontend-arena : i64
  0)
(define compiler-driver-pending-frontend-return-arena : i64
  0)

(defstruct CompilerDriverState
  (expr-pool (Array AstExprNodePoolState))
  (type-pool (Array AstTypeNodePoolState))
  (intern-state (Array ci.InternCompatState))
  (parser-state CompilerParseState)
  (builtin-ids (Array cbi.CompilerBuiltinIdsState))
  (lower-arenas (Array CompilerLowerArenaState))
  (load-session CompilerLoadSessionState)
  (typecheck-state TcJobState)
  (typecheck-prefix-cache TcPrefixSnapshotCacheState)
  (pool-arena (Array i64))
  (surface-arena i64)
  (profile-state profile_state.CompilerProfileState))

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
    [surface-arena : i64 (arena.tl_arena_make)]
    ;; The typecheck caches share the driver's lifetime with hydrated surface
    ;; data. Allocate them in that already-reserved arena instead of extending
    ;; the process entry arena by a full segment near its capacity boundary.
    [previous-arena : i64 (arena.tl_arena_current)]
    [_set-surface-arena : unit
      (unsafe
        (arena.tl_arena_set surface-arena))]
    [typecheck-state : TcJobState (tc-job-state-new)]
    [_restore-previous-arena : unit
      (unsafe
        (arena.tl_arena_set previous-arena))]
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
        (compiler-parse-state-new-with-intern-state (array-ref intern-cell 0))
        builtin-cell
        lower-cell
        (compiler-load-session-state-new)
        typecheck-state
        (tc-prefix-snapshot-cache-state-new)
        pool-arena-cell
        surface-arena
        (profile_state.compiler-profile-state-new)))))

;; State-owned pools allocate fixed-size segments on demand. One expression
;; segment covers tiny programs while self-host-sized compiles append segments
;; without relocating earlier nodes or retaining an eager multi-million-slot
;; reserve.
(define compiler-driver-compile-load-expr-pool-initial-capacity : i64
  1)

;; The checked generation uses the same single-segment starting point and grows
;; independently from the source generation.
(define compiler-driver-checked-lower-expr-pool-initial-capacity : i64
  1)

;; Type nodes are hash-consed and use smaller on-demand segments. The dedup
;; index retains enough slots for the measured selfhost unique-type set.
(define compiler-driver-compile-type-pool-initial-capacity : i64
  1)

;; A process-lifetime one-slot compatibility target used only to detach legacy
;; globals before an explicitly owned pool arena is destroyed. Production jobs
;; do not read or write through this context; their next load receives its
;; `AstNodePoolContext` directly.
(define compiler-driver-detached-compat-pools : AstNodePoolContext
  ;; This sentinel is never read or written. Snapshot the process-global
  ;; compatibility fallback instead of allocating a duplicate 64K expression
  ;; segment into the process-lifetime default arena.
  (ast-node-pool-context-capture-active))

(define (compiler-driver-state-detach-active-pools-if-owned!
  [pools : AstNodePoolContext]) : unit
  (if (=
    (ast-node-pool-owner-arena-handle)
    (ast-node-pool-context-owner-arena pools))
    (ast-node-pool-context-install! compiler-driver-detached-compat-pools)
    unit))

(define (compiler-driver-state-new-for-compile) : CompilerDriverState
  (let
    [pool-arena : i64 (ast-node-pool-arena-make)]
    [pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena
        compiler-driver-compile-load-expr-pool-initial-capacity
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

(define (compiler-driver-state-profile [state : CompilerDriverState]) : profile_state.CompilerProfileState
  (struct-get state profile-state))

(define (compiler-driver-state-typecheck-prefix-cache
  [state : CompilerDriverState]) : TcPrefixSnapshotCacheState
  (struct-get state typecheck-prefix-cache))

(define (compiler-driver-state-typecheck [state : CompilerDriverState]) : TcJobState
  (struct-get state typecheck-state))

(define (compiler-driver-state-reset-typecheck! [state : CompilerDriverState]) : unit
  (tc-job-state-reset-file-state! (compiler-driver-state-typecheck state)))

(define (compiler-driver-state-prefix-cache-enable!
  [state : CompilerDriverState]) : unit
  (tc-prefix-snapshot-cache-enable-for-state!
    (compiler-driver-state-typecheck-prefix-cache state)))

(define (compiler-driver-state-prefix-cache-disable!
  [state : CompilerDriverState]) : unit
  (tc-prefix-snapshot-cache-disable-for-state!
    (compiler-driver-state-typecheck-prefix-cache state)))

(define (compiler-driver-state-prefix-cache-clear!
  [state : CompilerDriverState]) : unit
  (tc-prefix-snapshot-cache-clear-for-state!
    (compiler-driver-state-typecheck-prefix-cache state)))

(define (compiler-driver-state-prefix-cache-print-stats
  [state : CompilerDriverState]
  [label : String]) : unit
  (tc-prefix-snapshot-cache-print-stats-for-state
    (compiler-driver-state-typecheck-prefix-cache state)
    label))

(define (compiler-driver-state-session-program-cache-disable
  [state : CompilerDriverState]) : CompilerDriverState
  (begin
    (compiler-load-session-state-program-cache-disable!
      (struct-get state load-session))
    state))

(define (compiler-driver-state-apply-session-flags!
  [state : CompilerDriverState]) : unit
  (compiler-load-session-state-use-with-intern-state!
    (struct-get state load-session)
    (array-ref (struct-get state intern-state) 0)))

;; Legacy/test adapter for compiler phases that still use the active pool
;; globals. State-owned reset/adopt operations must not call this helper.
(define (compiler-driver-state-install-pools! [state : CompilerDriverState]) : unit
  (begin
    (array-set!
      compiler-driver-active-state-pool-arena
      0
      (compiler-driver-state-owned-pool-arena state))
    (array-set!
      compiler-driver-active-state-surface-arena
      0
      (compiler-driver-state-surface-arena state))
    (ast-node-pool-context-install! (compiler-driver-state-pool-context state))))

;; The most recently installed driver state's own pool arena, or 0 when no
;; state is installed. The allocation snapshot reports this as `state-pool-arena`
;; because the compatibility pool-global handle deliberately points at the 1x1
;; detached compat pools (entry arena) once the source arena is detached, so
;; `compiler-driver-node-pool-base-arena` cannot name the checked-program arena.
(define compiler-driver-active-state-pool-arena : (Array i64)
  (array.make-array i64 1))
(define compiler-driver-active-state-surface-arena : (Array i64)
  (array.make-array i64 1))

;; Legacy/test adapter for the remaining load/typecheck/lower call graph.
;; State-owned table and persistent-arena maintenance uses the explicit
;; `InternCompatState` APIs and must happen before this boundary.
(define (compiler-driver-state-install-interns! [state : CompilerDriverState]) : unit
  (ci.intern-compat-state-install!
    (array-ref (struct-get state intern-state) 0)))

(define (compiler-driver-node-pool-base-arena) : i64
  (ast-node-pool-base-arena-handle))

;; Emit owner candidates plus the active arena at stable compiler phase
;; boundaries. `arena_root` lets consumers de-duplicate an active arena that is
;; also one of the named owners.
(define (compiler-driver-allocation-profile-snapshot! [phase : String]) : unit
  (if (= (allocation_profile.compiler-allocation-profile-control! 0 "" "" 0) 0)
    unit
    (begin
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "active"
        (arena.tl_arena_current))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "compiler-entry"
        (allocation_profile.compiler-allocation-profile-entry-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "source-pools"
        (compiler-driver-node-pool-base-arena))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "state-pool-arena"
        (array-ref compiler-driver-active-state-pool-arena 0))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "state-surface-arena"
        (array-ref compiler-driver-active-state-surface-arena 0))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "expr-pool-storage"
        (ast-node-pool-expr-storage-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "type-pool-storage"
        (ast-node-pool-type-storage-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "intern-persistent"
        (ci.intern-persistent-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "ir-labels"
        (compiler-ir-label-arena-handle-value))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "load-provenance"
        (compiler-load-provenance-arena-handle-value))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "lexer-token-buffer"
        (compiler-load-lex-token-buffer-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "reader-node-pool"
        (compiler-load-reader-node-pool-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "reader-sexpr-pool"
        (compiler-load-reader-sexpr-pool-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "typecheck-aggregate-layout-cache"
        (tc-agg-layout-cache-storage-arena-handle-value))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "lower-scratch"
        lower-scratch-arena)
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "lower-ir"
        lower-ir-arena)
      unit)))

(define (compiler-driver-allocation-profile-pool-storage-snapshot!
  [phase : String]
  [pools : AstNodePoolContext]) : unit
  (if (= (allocation_profile.compiler-allocation-profile-control! 0 "" "" 0) 0)
    unit
    (begin
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "expr-pool-storage"
        (ast-node-pool-context-expr-storage-arena pools))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "type-pool-storage"
        (ast-node-pool-context-type-storage-arena pools))
      unit)))

(define (compiler-driver-state-prefix-cache-allocation-profile-snapshot!
  [state : CompilerDriverState]
  [phase : String]) : unit
  (if (= (allocation_profile.compiler-allocation-profile-control! 0 "" "" 0) 0)
    unit
    (begin
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "typecheck-prefix-cache"
        (tc-prefix-snapshot-cache-arena-value-for-state
          (compiler-driver-state-typecheck-prefix-cache state)))
      unit)))

(define (compiler-driver-allocation-profile-backend-output-snapshot!) : unit
  (if (= (allocation_profile.compiler-allocation-profile-control! 0 "" "" 0) 0)
    unit
    (begin
      (allocation_profile.compiler-allocation-profile-control!
        2
        "backend"
        "backend-output-home"
        (compiler-backend-assembly-stream-home-arena-handle-value))
      unit)))

(define (compiler-driver-state-pool-context [state : CompilerDriverState]) : AstNodePoolContext
  (ast-node-pool-context-from-cells
    (struct-get state expr-pool)
    (struct-get state type-pool)
    (array-ref (struct-get state pool-arena) 0)))

(define (compiler-driver-state-owned-pool-arena [state : CompilerDriverState]) : i64
  (array-ref (struct-get state pool-arena) 0))

(define (compiler-driver-state-surface-arena [state : CompilerDriverState]) : i64
  (struct-get state surface-arena))

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
      compiler-driver-active-state-pool-arena
      0
      (ast-node-pool-context-base-arena pools))
    (array-set!
      (struct-get state expr-pool)
      0
      (array-ref (struct-get pools expr-pool) 0))
    (array-set!
      (struct-get state type-pool)
      0
      (array-ref (struct-get pools type-pool) 0))))

(define (compiler-driver-state-can-release-checked-lower-source-pools?
  [state : CompilerDriverState]) : bool
  (and
    (compiler-driver-state-has-owned-pool-arena? state)
    (not (compiler-driver-state-session-cache-enabled? state))))

(define (compiler-driver-state-new-checked-lower-pools) : AstNodePoolContext
  (let
    [prev-arena : i64 (arena.tl_arena_current)]
    [pool-arena : i64 (ast-node-pool-arena-make)]
    [_set-pool-arena : unit
      (unsafe
        (arena.tl_arena_set pool-arena))]
    [pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena
        compiler-driver-checked-lower-expr-pool-initial-capacity
        compiler-driver-compile-type-pool-initial-capacity
        pool-arena)]
    (begin
      ;; Keep the context's wrapper cells with its backing arrays. Early source
      ;; retirement can otherwise unmap wrapper cells allocated in the frontend
      ;; arena before an error path gets a chance to release this pool.
      (unsafe
        (arena.tl_arena_set prev-arena))
      pools)))

(define (compiler-driver-state-destroy-uncommitted-pools!
  [pools : AstNodePoolContext]) : unit
  (begin
    ;; Checked lowering installs its destination pools into the compatibility
    ;; globals before it can fail. On an uncommitted error, detach that active
    ;; view before destroying the pool; otherwise batch cleanup can capture the
    ;; now-unmapped context cells after the diagnostic has been emitted.
    ;; Refs #5448.
    (compiler-driver-state-detach-active-pools-if-owned! pools)
    (ast-node-pool-context-destroy-storage! pools)
    (unsafe
      (arena.tl_arena_destroy (ast-node-pool-context-base-arena pools)))))

(define (compiler-driver-state-retain-lowered-types!
  [state : CompilerDriverState]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [pools : AstNodePoolContext]) : ResultCompilerDriverLowered
  (let
    [old-arena : i64 (ast-node-pool-context-base-arena pools)]
    [old-expr-storage-arena : i64
      (ast-node-pool-context-expr-storage-arena pools)]
    [old-type-storage-arena : i64
      (ast-node-pool-context-type-storage-arena pools)]
    [retained : AstNodePoolContext
      (ast-node-pool-context-clone-types-only pools)]
    (begin
      (compiler-driver-state-adopt-pools! state retained)
      ;; Optimizer/backend type reads use the explicit retained reader below.
      ;; Detach only when the active compatibility pool is the retiring source;
      ;; if another driver state owns it, leave that state's writer pool intact.
      (compiler-driver-state-detach-active-pools-if-owned! pools)
      ;; Standalone entry points can leave the retiring checked pool active;
      ;; move those to retained storage. Batch entry points instead have a
      ;; distinct caller-owned scratch arena that must remain active through
      ;; emission and be returned to batch cleanup.
      (if (= (arena.tl_arena_current) old-arena)
        (unsafe
          (arena.tl_arena_set (ast-node-pool-context-base-arena retained)))
        unit)
      (ast-node-pool-reader-use! retained)
      (compiler-driver-allocation-profile-pool-storage-snapshot!
        "retained-reader"
        retained)
      (cfg
        compile-profile
        (compiler-lower-profile-pools "retained_reader" retained)
        unit)
      (set! compiler-driver-pending-retired-source-arena old-arena)
      (set!
        compiler-driver-pending-retired-source-expr-storage-arena
        old-expr-storage-arena)
      (set!
        compiler-driver-pending-retired-source-type-storage-arena
        old-type-storage-arena)
      (compiler-driver-lowered-from-pools-and-profile-state
        program
        spans
        retained
        (compiler-driver-state-profile state)))))

(define (compiler-driver-state-clear-pool-backed-caches-for-state!
  [state : CompilerDriverState]) : unit
  (begin
    (compiler-load-session-state-floors-set!
      (struct-get state load-session)
      0
      0
      0)
    (compiler-load-session-state-program-cache-clear!
      (struct-get state load-session))
    (compiler-load-session-state-runtime-prelude-cache-clear!
      (struct-get state load-session))
    (tc-prefix-snapshot-cache-invalidate-for-state!
      (compiler-driver-state-typecheck-prefix-cache state))))

;; Serial compatibility adapter for the post-lowering arena retirement path.
(define (compiler-driver-state-clear-pool-backed-caches!) : unit
  (begin
    (compiler-load-session-floors-set! 0 0 0)
    (compiler-load-program-cache-clear!)
    (compiler-load-runtime-prelude-cache-clear!)
    (tc-prefix-snapshot-cache-clear!)))

(define (compiler-driver-state-replace-owned-pool-arena-if-uncached!
  [state : CompilerDriverState]
  [expr-capacity : i64]
  [type-capacity : i64]) : unit
  (if (or
    (not (compiler-driver-state-has-owned-pool-arena? state))
    (compiler-driver-state-session-cache-enabled? state))
    unit
    (let
      ;; The pool payload arena may grow past its root during a compile.
      ;; Destroy the installed head we just retired; the runtime root also tracks
      ;; that newest live segment so either head or root handle reclaims the chain.
      [old-newest : i64
        (ast-node-pool-context-base-arena
          (compiler-driver-state-pool-context state))]
      [new-arena : i64 (ast-node-pool-arena-make)]
      (begin
        (compiler-driver-state-clear-pool-backed-caches-for-state! state)
        ;; Do not materialize the replacement backing arrays while the retired
        ;; pool chain is still live. If that chain is also the active arena,
        ;; move allocation to the already-created replacement root first.
        (if (= (arena.tl_arena_current) old-newest)
          (unsafe
            (arena.tl_arena_set new-arena))
          unit)
        (compiler-driver-state-detach-active-pools-if-owned!
          (compiler-driver-state-pool-context state))
        (ast-node-pool-context-destroy-storage!
          (compiler-driver-state-pool-context state))
        (if (= (arena.tl_arena_current) old-newest)
          (unsafe
            (arena.tl_arena_set new-arena))
          unit)
        (unsafe
          (arena.tl_arena_destroy old-newest))
        (let
          [pools : AstNodePoolContext
            (ast-node-pool-context-new-with-capacities-in-arena
              expr-capacity
              type-capacity
              new-arena)]
          (begin
            (array-set!
              (struct-get state pool-arena)
              0
              (ast-node-pool-context-base-arena pools))
            ;; Keep the snapshot handle naming a live arena: the old pool
            ;; chain was destroyed above, and the next entry's load-phase
            ;; state-pool-arena row walks this global before any reinstall.
            (array-set!
              compiler-driver-active-state-pool-arena
              0
              (ast-node-pool-context-base-arena pools))
            (array-set!
              (struct-get state expr-pool)
              0
              (array-ref (struct-get pools expr-pool) 0))
            (array-set!
              (struct-get state type-pool)
              0
              (array-ref (struct-get pools type-pool) 0))))))))

(define (compiler-driver-state-reset-owned-pool-arena-if-uncached!
  [state : CompilerDriverState]) : unit
  (compiler-driver-state-replace-owned-pool-arena-if-uncached!
    state
    compiler-driver-compile-load-expr-pool-initial-capacity
    compiler-driver-compile-type-pool-initial-capacity))

;; Batch emission has finished using the entry's pools, but its caller-owned
;; scratch chain must remain mapped until loader/typecheck/lower cleanup is
;; complete. Replace the retired pool with only a valid one-slot compatibility
;; context here; the next entry's ordinary reset prepares full load capacity
;; after the previous scratch chain has been destroyed.
(define (compiler-driver-state-release-owned-pool-arena-if-uncached!
  [state : CompilerDriverState]) : unit
  (compiler-driver-state-replace-owned-pool-arena-if-uncached! state 1 1))

(define (compiler-driver-state-reset-owned-intern-arena-if-uncached!
  [state : CompilerDriverState]) : unit
  (if (or
    (not (compiler-driver-state-has-owned-pool-arena? state))
    (compiler-driver-state-session-cache-enabled? state))
    unit
    (ci.intern-compat-state-persistent-arena-reset!
      (array-ref (struct-get state intern-state) 0))))

(define (compiler-driver-state-install-builtins! [state : CompilerDriverState]) : unit
  (cbi.state-install! (array-ref (struct-get state builtin-ids) 0)))

(define (compiler-driver-state-install-lower-arenas!
  [state : CompilerDriverState]) : unit
  (compiler-lower-arena-state-install!
    (array-ref (struct-get state lower-arenas) 0)))

;; Legacy/test capture paired with `compiler-driver-state-install-interns!`.
(define (compiler-driver-state-capture-active-interns!
  [state : CompilerDriverState]) : unit
  (ci.intern-compat-state-capture-from-globals!
    (array-ref (struct-get state intern-state) 0)))

(define (compiler-driver-state-intern-generation [state : CompilerDriverState]) : i64
  (ci.intern-compat-state-generation
    (array-ref (struct-get state intern-state) 0)))

(define (compiler-driver-state-owned-interns [state : CompilerDriverState]) : ci.InternCompatState
  (array-ref (struct-get state intern-state) 0))

(define (compiler-driver-state-capture-active-builtins!
  [state : CompilerDriverState]) : unit
  (cbi.state-capture-from-globals! (array-ref (struct-get state builtin-ids) 0)))

(define (compiler-driver-state-reset-builtins! [state : CompilerDriverState]) : unit
  (begin
    (cbi.state-reset! (array-ref (struct-get state builtin-ids) 0))
    (compiler-driver-state-install-builtins! state)))

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
    ;; Load/typecheck/lower mutate the state-owned context cells directly; do
    ;; not overwrite them from whichever compatibility pool happens to be
    ;; installed when a batch entry finishes, and do not install the loader's
    ;; serial/test selector as a compile-job handoff.
    (compiler-driver-state-capture-active-interns! state)
    (compiler-driver-state-capture-active-transients! state)))

(define (compiler-driver-lowered-from-active-pools-and-profile-state
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverLowered
  (ResultCompilerDriverLowered.Ok
    program
    spans
    (ast-node-pool-context-capture-active)
    profile-state))

(define (compiler-driver-lowered-from-active-pools
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]) : ResultCompilerDriverLowered
  (compiler-driver-lowered-from-active-pools-and-profile-state
    program
    spans
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-lowered-from-pools
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [pools : AstNodePoolContext]) : ResultCompilerDriverLowered
  (ResultCompilerDriverLowered.Ok
    program
    spans
    (ast-node-pool-context-snapshot pools)
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-lowered-from-pools-and-profile-state
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [pools : AstNodePoolContext]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverLowered
  (ResultCompilerDriverLowered.Ok
    program
    spans
    (ast-node-pool-context-snapshot pools)
    profile-state))

(define (compiler-driver-runtime-prelude-cache-lookup-with-state
  [load-state : CompilerLoadSessionState]
  [key : CompilerLoadPreludeCacheKey]) : CompilerLoadPreludeCacheLookup
  (compiler-load-session-state-runtime-prelude-cache-lookup load-state key))

;; Helpers in this section that omit `load-state` are serial/test compatibility
;; adapters. Driver-owned compile paths call the explicit state-taking forms.
(define (compiler-driver-runtime-prelude-cache-lookup
  [key : CompilerLoadPreludeCacheKey]) : CompilerLoadPreludeCacheLookup
  (compiler-driver-runtime-prelude-cache-lookup-with-state
    compiler-load-active-session-state
    key))

(define (compiler-driver-runtime-prelude-cache-store-with-state
  [load-state : CompilerLoadSessionState]
  [key : CompilerLoadPreludeCacheKey]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]) : unit
  (compiler-load-session-state-runtime-prelude-cache-store
    load-state
    key
    decls
    paths
    modules
    seen))

(define (compiler-driver-runtime-prelude-cache-store
  [key : CompilerLoadPreludeCacheKey]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]) : unit
  (compiler-driver-runtime-prelude-cache-store-with-state
    compiler-load-active-session-state
    key
    decls
    paths
    modules
    seen))

(define (compiler-driver-runtime-prelude-cache-store-with-state-and-pools
  [load-state : CompilerLoadSessionState]
  [key : CompilerLoadPreludeCacheKey]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : unit
  (compiler-load-session-state-runtime-prelude-cache-store-with-pools
    load-state
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
    (compiler-load-default-session-use!)
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
    (compiler-driver-state-reset-owned-intern-arena-if-uncached! state)
    (let
      [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
      (begin
        (compiler-load-session-state-reset-pools-with-pools!
          (struct-get state load-session)
          pools)
        (compiler-load-session-state-reset-interns-with-state!
          (struct-get state load-session)
          (array-ref (struct-get state intern-state) 0))
        (compiler-driver-state-reset-typecheck! state)
        (compiler-typecheck-reset-intern-owned-state!)
        (compiler-driver-state-install-transients! state)
        (compiler-driver-state-reset-builtins! state)
        (ctfe-builtin-reset!)
        (compiler-typecheck-reset-file-state!)
        (lower-reset-file-state!)
        ;; Drop the previous entry's lowerer arenas. At opt level 0
        ;; the escaped IR stays alive until the next file reset.
        (lower-arenas-release!)
        (compiler-driver-state-capture-active-transients! state)))))

;; Post-emission batch cleanup. This runs while the caller-owned entry scratch
;; arena is still live, so it performs the same cache/intern/lower teardown as a
;; full file reset but leaves only a one-slot pool context behind. The next
;; entry's normal reset grows a fresh load pool after the old scratch chain is
;; gone instead of keeping a 4.39M-slot replacement live between entries.
(define (compiler-driver-state-release-file-state!
  [state : CompilerDriverState]) : unit
  (begin
    (compiler-driver-state-apply-session-flags! state)
    (compiler-driver-state-release-owned-pool-arena-if-uncached! state)
    (compiler-driver-state-reset-owned-intern-arena-if-uncached! state)
    (let
      [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
      (begin
        (compiler-load-session-state-reset-pools-with-pools!
          (struct-get state load-session)
          pools)
        (compiler-load-session-state-reset-interns-with-state!
          (struct-get state load-session)
          (array-ref (struct-get state intern-state) 0))
        (compiler-driver-state-reset-typecheck! state)
        (compiler-typecheck-reset-intern-owned-state!)
        (compiler-driver-state-install-transients! state)
        (compiler-driver-state-reset-builtins! state)
        (ctfe-builtin-reset!)
        (compiler-typecheck-reset-file-state!)
        (lower-reset-file-state!)
        (lower-arenas-release!)
        (compiler-driver-state-capture-active-transients! state)))))

(cfg
  compile-profile
  (define (compiler-driver-state-release-file-state-profiled!
    [state : CompilerDriverState]
    [ordinal : i64]) : unit
    (begin
      (compiler-driver-state-apply-session-flags! state)
      ;; Post-emission cleanup deliberately installs only the compact one-slot
      ;; compatibility context. The next entry prepares full load capacity
      ;; after this entry's scratch chain is gone.
      (compiler-driver-state-release-owned-pool-arena-if-uncached! state)
      (compiler-driver-batch-profile-mark!
        (compiler-driver-state-profile state)
        ordinal
        "owned-pool-release")
      (compiler-driver-state-reset-owned-intern-arena-if-uncached! state)
      (let
        [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
        (begin
          (compiler-load-session-state-reset-pools-with-pools!
            (struct-get state load-session)
            pools)
          (compiler-load-session-state-reset-interns-with-state!
            (struct-get state load-session)
            (array-ref (struct-get state intern-state) 0))
          (compiler-driver-state-reset-typecheck! state)
          (compiler-typecheck-reset-intern-owned-state!)
          (compiler-driver-state-install-transients! state)
          (compiler-driver-state-reset-builtins! state)
          (ctfe-builtin-reset!)
          (compiler-typecheck-reset-file-state!)
          (compiler-driver-batch-profile-mark!
            (compiler-driver-state-profile state)
            ordinal
            "intern-session-cleanup")
          (lower-reset-file-state!)
          (lower-arenas-release!)
          (compiler-driver-batch-profile-mark!
            (compiler-driver-state-profile state)
            ordinal
            "lower-cleanup")
          (compiler-driver-state-capture-active-transients! state))))))

(cfg
  compile-profile
  (define compiler-driver-profile-total-start-ms-metric : i64
    0))
(cfg
  compile-profile
  (define compiler-driver-profile-total-start-total-metric : i64
    1))
(cfg
  compile-profile
  (define compiler-driver-profile-total-start-live-metric : i64
    2))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-ms-metric : i64
    3))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-total-metric : i64
    4))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-live-metric : i64
    5))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-intern-metric : i64
    6))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-intern-slice-metric : i64
    7))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-intern-generated-metric : i64
    8))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-intern-render-metric : i64
    9))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-intern-lookup-metric : i64
    10))
(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-intern-pool-len-metric : i64
    11))
(cfg
  compile-profile
  (define compiler-driver-profile-prelude-source-pipeline-entries : i64
    0))
(cfg
  compile-profile
  (define compiler-driver-profile-prelude-hydrations : i64
    0))
(cfg
  compile-profile
  (define compiler-driver-batch-profile-start-ms-metric : i64
    14))
(cfg
  compile-profile
  (define compiler-driver-batch-profile-start-total-metric : i64
    15))
(cfg
  compile-profile
  (define compiler-driver-batch-profile-start-live-metric : i64
    16))
(cfg
  compile-profile
  (define compiler-driver-batch-profile-best-peak-metric : i64
    17))
(cfg
  compile-profile
  (define compiler-driver-batch-profile-first-live-metric : i64
    18))

(cfg
  compile-profile
  (define (compiler-driver-profile-value
    [state : profile_state.CompilerProfileState]
    [metric : i64]) : i64
    (profile_state.compiler-profile-state-metric-value state metric)))

(cfg
  compile-profile
  (define (compiler-driver-profile-set!
    [state : profile_state.CompilerProfileState]
    [metric : i64]
    [value : i64]) : unit
    (profile_state.compiler-profile-state-metric-set! state metric value)))

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
  (define (compiler-driver-batch-profile-line
    [ordinal : i64]
    [marker : String]
    [elapsed-ms : i64]
    [alloc-delta : i64]
    [live-delta : i64]
    [peak-delta : i64]
    [live-bytes : i64]
    [baseline-delta : i64]) : String
    (string.append
      "\ncompile-batch-profile|"
      (string.append
        (string.int->string ordinal)
        (string.append
          "|"
          (string.append
            marker
            (string.append
              (compiler-driver-profile-field elapsed-ms)
              (string.append
                (compiler-driver-profile-field alloc-delta)
                (string.append
                  (compiler-driver-profile-field live-delta)
                  (string.append
                    (compiler-driver-profile-field peak-delta)
                    (string.append
                      (compiler-driver-profile-field live-bytes)
                      (string.append
                        (compiler-driver-profile-field baseline-delta)
                        "\n"))))))))))))

(cfg
  compile-profile
  (define (compiler-driver-batch-profile-reset-baseline!
    [state : profile_state.CompilerProfileState]) : unit
    (begin
      (compiler-driver-profile-set!
        state
        compiler-driver-batch-profile-start-ms-metric
        (profile.now-ms))
      (compiler-driver-profile-set!
        state
        compiler-driver-batch-profile-start-total-metric
        (profile.alloc-total))
      (compiler-driver-profile-set!
        state
        compiler-driver-batch-profile-start-live-metric
        (profile.alloc-live))
      (profile.alloc-reset-peak))))

(cfg
  compile-profile
  (define (compiler-driver-batch-profile-start-entry!
    [state : profile_state.CompilerProfileState]
    [ordinal : i64]) : unit
    (let
      [live-bytes : i64 (profile.alloc-live)]
      (begin
        (if (= ordinal 0)
          (begin
            (io.print-error
              "compile-batch-profile|entry_ordinal|marker|elapsed_ms|alloc_delta_bytes|live_delta_bytes|peak_live_delta_bytes|live_bytes|entry0_baseline_delta_bytes\n")
            (compiler-driver-profile-set!
              state
              compiler-driver-batch-profile-first-live-metric
              live-bytes))
          unit)
        (compiler-driver-profile-set!
          state
          compiler-driver-batch-profile-best-peak-metric
          0)
        (compiler-driver-batch-profile-reset-baseline! state)
        (io.print-error
          (compiler-driver-batch-profile-line
            ordinal
            "entry-start"
            0
            0
            0
            0
            live-bytes
            (-
              live-bytes
              (compiler-driver-profile-value
                state
                compiler-driver-batch-profile-first-live-metric))))))))

(cfg
  compile-profile
  (define (compiler-driver-batch-profile-mark!
    [state : profile_state.CompilerProfileState]
    [ordinal : i64]
    [marker : String]) : unit
    (let
      [end-ms : i64 (profile.now-ms)]
      [end-total : i64 (profile.alloc-total)]
      [end-live : i64 (profile.alloc-live)]
      [peak-delta : i64
        (compiler-driver-profile-max
          (compiler-driver-profile-value
            state
            compiler-driver-batch-profile-best-peak-metric)
          (compiler-driver-profile-nonnegative
            (-
              (profile.alloc-peak)
              (compiler-driver-profile-value
                state
                compiler-driver-batch-profile-start-live-metric))))]
      (begin
        (io.print-error
          (compiler-driver-batch-profile-line
            ordinal
            marker
            (-
              end-ms
              (compiler-driver-profile-value
                state
                compiler-driver-batch-profile-start-ms-metric))
            (-
              end-total
              (compiler-driver-profile-value
                state
                compiler-driver-batch-profile-start-total-metric))
            (-
              end-live
              (compiler-driver-profile-value
                state
                compiler-driver-batch-profile-start-live-metric))
            peak-delta
            end-live
            (-
              end-live
              (compiler-driver-profile-value
                state
                compiler-driver-batch-profile-first-live-metric))))
        (compiler-driver-profile-set!
          state
          compiler-driver-batch-profile-best-peak-metric
          0)
        (compiler-driver-batch-profile-reset-baseline! state)))))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-phase
    [state : profile_state.CompilerProfileState]) : unit
    (begin
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-phase-start-ms-metric
        (profile.now-ms))
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-phase-start-total-metric
        (profile.alloc-total))
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-phase-start-live-metric
        (profile.alloc-live))
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-phase-start-intern-metric
        (ci.intern-profile-intern-value))
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-phase-start-intern-slice-metric
        (ci.intern-profile-slice-value))
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-phase-start-intern-generated-metric
        (ci.intern-profile-generated-value))
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-phase-start-intern-render-metric
        (ci.intern-profile-render-value))
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-phase-start-intern-lookup-metric
        (ci.intern-profile-lookup-value))
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-phase-start-intern-pool-len-metric
        (ci.intern-pool-len))
      (profile.alloc-reset-peak))))

(cfg
  compile-profile
  (define (compiler-driver-profile-finish-phase
    [state : profile_state.CompilerProfileState]
    [phase : String]) : unit
    (let
      [end-ms : i64 (profile.now-ms)]
      [end-total : i64 (profile.alloc-total)]
      [end-live : i64 (profile.alloc-live)]
      [end-peak : i64 (profile.alloc-peak)]
      [end-intern : i64 (ci.intern-profile-intern-value)]
      [end-intern-slice : i64 (ci.intern-profile-slice-value)]
      [end-intern-generated : i64 (ci.intern-profile-generated-value)]
      [end-intern-render : i64 (ci.intern-profile-render-value)]
      [end-intern-lookup : i64 (ci.intern-profile-lookup-value)]
      [end-intern-pool-len : i64 (ci.intern-pool-len)]
      [peak-delta : i64
        (compiler-driver-profile-nonnegative
          (-
            end-peak
            (compiler-driver-profile-value
              state
              compiler-driver-profile-phase-start-live-metric)))]
      (begin
        (compiler-driver-profile-set!
          state
          compiler-driver-batch-profile-best-peak-metric
          (compiler-driver-profile-max
            (compiler-driver-profile-value
              state
              compiler-driver-batch-profile-best-peak-metric)
            peak-delta))
        (io.print-error
          (compiler-driver-profile-line
            phase
            (-
              end-ms
              (compiler-driver-profile-value
                state
                compiler-driver-profile-phase-start-ms-metric))
            (-
              end-total
              (compiler-driver-profile-value
                state
                compiler-driver-profile-phase-start-total-metric))
            (-
              end-live
              (compiler-driver-profile-value
                state
                compiler-driver-profile-phase-start-live-metric))
            peak-delta))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (string.append
              "compile-profile-detail|intern.phase|"
              (string.append
                phase
                (string.append
                  "|"
                  (string.append
                    (string.int->string
                      (-
                        end-intern
                        (compiler-driver-profile-value
                          state
                          compiler-driver-profile-phase-start-intern-metric)))
                    "\n"))))))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (string.append
              "compile-profile-detail|intern.phase.slice|"
              (string.append
                phase
                (string.append
                  "|"
                  (string.append
                    (string.int->string
                      (-
                        end-intern-slice
                        (compiler-driver-profile-value
                          state
                          compiler-driver-profile-phase-start-intern-slice-metric)))
                    "\n"))))))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (string.append
              "compile-profile-detail|intern.phase.generated|"
              (string.append
                phase
                (string.append
                  "|"
                  (string.append
                    (string.int->string
                      (-
                        end-intern-generated
                        (compiler-driver-profile-value
                          state
                          compiler-driver-profile-phase-start-intern-generated-metric)))
                    "\n"))))))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (string.append
              "compile-profile-detail|intern.phase.render|"
              (string.append
                phase
                (string.append
                  "|"
                  (string.append
                    (string.int->string
                      (-
                        end-intern-render
                        (compiler-driver-profile-value
                          state
                          compiler-driver-profile-phase-start-intern-render-metric)))
                    "\n"))))))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (string.append
              "compile-profile-detail|intern.phase.lookup|"
              (string.append
                phase
                (string.append
                  "|"
                  (string.append
                    (string.int->string
                      (-
                        end-intern-lookup
                        (compiler-driver-profile-value
                          state
                          compiler-driver-profile-phase-start-intern-lookup-metric)))
                    "\n"))))))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (string.append
              "compile-profile-detail|intern.phase.pool|"
              (string.append
                phase
                (string.append
                  "|"
                  (string.append
                    (string.int->string
                      (-
                        end-intern-pool-len
                        (compiler-driver-profile-value
                          state
                          compiler-driver-profile-phase-start-intern-pool-len-metric)))
                    "\n"))))))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (string.append
              "compile-profile-detail|intern.phase.invalid_str_ids|"
              (string.append
                phase
                (string.append
                  "|"
                  (string.append
                    (string.int->string (ci.intern-profile-invalid-str-value))
                    "\n"))))))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-total
    [state : profile_state.CompilerProfileState]) : unit
    (begin
      (set! compiler-driver-profile-prelude-source-pipeline-entries 0)
      (set! compiler-driver-profile-prelude-hydrations 0)
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-total-start-ms-metric
        (profile.now-ms))
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-total-start-total-metric
        (profile.alloc-total))
      (compiler-driver-profile-set!
        state
        compiler-driver-profile-total-start-live-metric
        (profile.alloc-live))
      (profile.compile-wide-peak-start!)
      (ci.intern-profile-reset!)
      (ctfe-env-profile-reset!)
      (cfg
        compile-profile-summary
        (begin
          (compiler-opt-profile-summary-reset! state)
          (compiler-backend-profile-summary-reset! state))
        unit)
      (io.print-error
        "compile-profile|phase|elapsed_ms|alloc_delta_bytes|live_delta_bytes|peak_live_delta_bytes\n")
      (cfg
        compile-profile-summary
        (io.print-error
          "compile-profile-summary|scope|kind|rank|name|elapsed_ms|calls\n")
        unit)
      (compiler-driver-profile-start-phase state))))

(cfg
  compile-profile
  (define (compiler-driver-profile-prelude-counters) : unit
    (cfg
      compile-profile-summary
      unit
      (begin
        (io.print-error
          (string.append
            "compile-profile-detail|prelude.source_pipeline_entries|"
            (string.append
              (string.int->string
                compiler-driver-profile-prelude-source-pipeline-entries)
              "\n")))
        (io.print-error
          (string.append
            "compile-profile-detail|prelude.hydrations|"
            (string.append
              (string.int->string compiler-driver-profile-prelude-hydrations)
              "\n")))))))

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
  (define (compiler-driver-profile-ctfe-env-line [name : String] [value : i64]) : unit
    (io.print-error
      (string.append
        "compile-profile|ctfe_env."
        (string.append
          name
          (string.append (compiler-driver-profile-field value) "|0|0|0\n"))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-finish-total
    [state : profile_state.CompilerProfileState]) : unit
    (let
      [compile-wide-peak : i64 (profile.compile-wide-peak-finish!)]
      (begin
        (io.print-error
          (compiler-driver-profile-line
            "total"
            (-
              (profile.now-ms)
              (compiler-driver-profile-value
                state
                compiler-driver-profile-total-start-ms-metric))
            (-
              (profile.alloc-total)
              (compiler-driver-profile-value
                state
                compiler-driver-profile-total-start-total-metric))
            (-
              (profile.alloc-live)
              (compiler-driver-profile-value
                state
                compiler-driver-profile-total-start-live-metric))
            compile-wide-peak))
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
          "generated_allocations"
          (ci.intern-profile-generated-value))
        (compiler-driver-profile-intern-line
          "render_calls"
          (ci.intern-profile-render-value))
        (compiler-driver-profile-intern-line
          "lookup_calls"
          (ci.intern-profile-lookup-value))
        (compiler-driver-profile-intern-line
          "source_bytes"
          (ci.intern-profile-source-bytes-value))
        (compiler-driver-profile-intern-line
          "source_symbols"
          (ci.intern-profile-source-symbol-value))
        (compiler-driver-profile-intern-line
          "source_symbol_bytes"
          (ci.intern-profile-source-symbol-bytes-value))
        (compiler-driver-profile-intern-line
          "slice_bytes"
          (ci.intern-profile-slice-bytes-value))
        (compiler-driver-profile-intern-line
          "slice_hits"
          (ci.intern-profile-slice-hit-value))
        (compiler-driver-profile-intern-line
          "slice_misses"
          (ci.intern-profile-slice-miss-value))
        (compiler-driver-profile-ctfe-env-line
          "binding_appends"
          (ctfe-env-profile-binding-appends-value))
        (compiler-driver-profile-ctfe-env-line
          "value_lookups"
          (ctfe-env-profile-value-lookups-value))
        (compiler-driver-profile-ctfe-env-line
          "type_lookups"
          (ctfe-env-profile-type-lookups-value))
        (compiler-driver-profile-ctfe-env-line
          "lookup_steps"
          (ctfe-env-profile-lookup-steps-value))
        (compiler-driver-profile-ctfe-env-line
          "local_set_calls"
          (ctfe-env-profile-local-set-calls-value))
        (compiler-driver-profile-ctfe-env-line
          "local_set_steps"
          (ctfe-env-profile-local-set-steps-value))
        (compiler-driver-profile-ctfe-env-line
          "arena_roots"
          (ctfe-env-profile-arena-roots-value))
        (compiler-driver-profile-ctfe-env-line
          "arena_grows"
          (ctfe-env-profile-arena-grows-value))))))

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
  (target_cfg.compiler-target-enable-linux-cfgs cfgs))

(define (compiler-driver-enable-windows-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-enable-windows-cfgs cfgs))

(define (compiler-driver-enable-linux-cfgs-with-intern-state
  [cfgs : sym_i64_env.SymI64Env]
  [intern-state : ci.InternCompatState]) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-enable-linux-cfgs-with-intern-state
    cfgs
    intern-state))

(define (compiler-driver-enable-windows-cfgs-with-intern-state
  [cfgs : sym_i64_env.SymI64Env]
  [intern-state : ci.InternCompatState]) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-enable-windows-cfgs-with-intern-state
    cfgs
    intern-state))

(define (compiler-driver-target-cfgs
  [target : CompilerBackendTarget]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (match target
      [(CompilerBackendTarget.Linux) (compiler-driver-enable-linux-cfgs cfgs)]
      [(CompilerBackendTarget.Windows)
        (compiler-driver-enable-windows-cfgs cfgs)])))

(define (compiler-driver-state-target-cfgs
  [state : CompilerDriverState]
  [target : CompilerBackendTarget]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [intern-state : ci.InternCompatState
      (array-ref (struct-get state intern-state) 0)]
    (match target
      [(CompilerBackendTarget.Linux)
        (compiler-driver-enable-linux-cfgs-with-intern-state cfgs intern-state)]
      [(CompilerBackendTarget.Windows)
        (compiler-driver-enable-windows-cfgs-with-intern-state
          cfgs
          intern-state)])))

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
  (compiler-driver-emit-lowered-with-level-mode-entry-and-crt-and-profile-state
    (ast-node-pool-reader-context-current)
    input-path
    program
    spans
    target
    has-target
    mode
    opt-level
    emit-entry
    false
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-emit-lowered-with-level-mode-entry-and-crt-and-profile-state
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriver
  (if (ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriver.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (compiler-driver-retire-frontend-arena!)
      (cfg compile-profile (compiler-driver-profile-start-phase profile-state))
      (match (optimize-program-with-spans-and-pools-and-level-and-profile-state
        pools
        program
        spans
        opt-level
        profile-state)
        [(CompilerOptimizedProgram.Program optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase profile-state "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerDriver.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
              (begin
                (compiler-backend-set-scalar-registers! (>= opt-level 2))
                (cfg
                  compile-profile
                  (compiler-driver-profile-start-phase profile-state))
                (match (if has-target
                  (compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state
                    pools
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    profile-state)
                  (compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state
                    pools
                    optimized
                    (CompilerBackendTarget.Linux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    profile-state))
                  [(ResultCompilerBackend.Ok asm)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          profile-state
                          "backend"))
                      (ResultCompilerDriver.Ok asm))]
                  [(ResultCompilerBackend.Err diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          profile-state
                          "backend"))
                      (ResultCompilerDriver.Err
                        (box
                          (compiler-diagnostic-with-path
                            (box-get diag)
                            input-path))))]))))]))))

(define (compiler-driver-emit-lowered-buffer-with-level-mode-entry-and-crt-and-profile-state
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverBuffer
  (if (ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriverBuffer.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (compiler-driver-retire-frontend-arena!)
      (cfg compile-profile (compiler-driver-profile-start-phase profile-state))
      (match (optimize-program-with-spans-and-pools-and-level-and-profile-state
        pools
        program
        spans
        opt-level
        profile-state)
        [(CompilerOptimizedProgram.Program optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase profile-state "optimize"))
            (compiler-driver-allocation-profile-snapshot! "optimize")
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerDriverBuffer.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
              (begin
                (compiler-backend-set-scalar-registers! (>= opt-level 2))
                (cfg
                  compile-profile
                  (compiler-driver-profile-start-phase profile-state))
                (match (if has-target
                  (compiler-backend-emit-program-target-with-mode-final-buffer-with-pools-and-crt-and-profile-state
                    pools
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    profile-state)
                  (compiler-backend-emit-program-target-with-mode-final-buffer-with-pools-and-crt-and-profile-state
                    pools
                    optimized
                    (CompilerBackendTarget.Linux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    profile-state))
                  [(ResultCompilerBackendBuffer.Ok asm)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          profile-state
                          "backend"))
                      (compiler-driver-allocation-profile-snapshot! "backend")
                      (compiler-driver-allocation-profile-backend-output-snapshot!)
                      (ResultCompilerDriverBuffer.Ok asm))]
                  [(ResultCompilerBackendBuffer.Err diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          profile-state
                          "backend"))
                      (compiler-driver-allocation-profile-snapshot! "backend")
                      (compiler-driver-allocation-profile-backend-output-snapshot!)
                      (ResultCompilerDriverBuffer.Err
                        (box
                          (compiler-diagnostic-with-path
                            (box-get diag)
                            input-path))))]))))]))))

(define (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt-and-profile-state
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverObject
  (if (ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriverObject.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (compiler-driver-retire-frontend-arena!)
      (cfg compile-profile (compiler-driver-profile-start-phase profile-state))
      (match (optimize-program-with-spans-and-pools-and-level-and-profile-state
        pools
        program
        spans
        opt-level
        profile-state)
        [(CompilerOptimizedProgram.Program optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase profile-state "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerDriverObject.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
              (begin
                (compiler-backend-set-scalar-registers! (>= opt-level 2))
                (cfg
                  compile-profile
                  (compiler-driver-profile-start-phase profile-state))
                (match (if has-target
                  (compiler-backend-emit-program-object-image-target-with-mode-with-pools-and-crt-and-profile-state
                    pools
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    profile-state)
                  (compiler-backend-emit-program-object-image-target-with-mode-with-pools-and-crt-and-profile-state
                    pools
                    optimized
                    (CompilerBackendTarget.Linux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    profile-state))
                  [(ResultCompilerBackendObject.Ok image)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          profile-state
                          "backend"))
                      (ResultCompilerDriverObject.Ok image))]
                  [(ResultCompilerBackendObject.Err diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          profile-state
                          "backend"))
                      (ResultCompilerDriverObject.Err
                        (box
                          (compiler-diagnostic-with-path
                            (box-get diag)
                            input-path))))]))))]))))

(define (compiler-driver-emit-lowered-pic-with-level-mode-entry-and-crt-and-profile-state
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverPic
  (if (ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriverPic.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (compiler-driver-retire-frontend-arena!)
      (cfg compile-profile (compiler-driver-profile-start-phase profile-state))
      (match (optimize-program-with-spans-and-pools-and-level-and-profile-state
        pools
        program
        spans
        opt-level
        profile-state)
        [(CompilerOptimizedProgram.Program optimized optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase profile-state "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerDriverPic.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
              (begin
                (compiler-backend-set-scalar-registers! (>= opt-level 2))
                (cfg
                  compile-profile
                  (compiler-driver-profile-start-phase profile-state))
                (match (if has-target
                  (compiler-backend-emit-program-pic-target-with-mode-with-pools-and-crt-and-profile-state
                    pools
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    profile-state)
                  (compiler-backend-emit-program-pic-target-with-mode-with-pools-and-crt-and-profile-state
                    pools
                    optimized
                    (CompilerBackendTarget.Linux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    profile-state))
                  [(ResultCompilerBackendPic.Ok output)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          profile-state
                          "backend"))
                      (ResultCompilerDriverPic.Ok output))]
                  [(ResultCompilerBackendPic.Err diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          profile-state
                          "backend"))
                      (ResultCompilerDriverPic.Err
                        (box
                          (compiler-diagnostic-with-path
                            (box-get diag)
                            input-path))))]))))]))))

;; Serial/test compatibility adapters. Driver-owned compile paths carry the
;; state from ResultCompilerDriverLowered into the explicit variants above.
(define (compiler-driver-emit-lowered-with-level-mode-entry-and-crt
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-with-level-mode-entry-and-crt-and-profile-state
    pools
    input-path
    program
    spans
    target
    has-target
    mode
    opt-level
    emit-entry
    crt-entry
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-emit-lowered-buffer-with-level-mode-entry-and-crt
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverBuffer
  (compiler-driver-emit-lowered-buffer-with-level-mode-entry-and-crt-and-profile-state
    pools
    input-path
    program
    spans
    target
    has-target
    mode
    opt-level
    emit-entry
    crt-entry
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverObject
  (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt-and-profile-state
    pools
    input-path
    program
    spans
    target
    has-target
    mode
    opt-level
    emit-entry
    crt-entry
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-emit-lowered-pic-with-level-mode-entry-and-crt
  [pools : AstNodePoolContext]
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverPic
  (compiler-driver-emit-lowered-pic-with-level-mode-entry-and-crt-and-profile-state
    pools
    input-path
    program
    spans
    target
    has-target
    mode
    opt-level
    emit-entry
    crt-entry
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-arena-owner-root [handle : i64]) : i64
  (if (= handle 0)
    0
    (let
      [root : i64
        (unsafe
          (ptr-read (ptr-offset (int->ptr handle : (Ptr i64)) 5)))]
      (if (= root 0)
        handle
        root))))

(define (compiler-driver-arena-owner-current-head [handle : i64]) : i64
  (let
    [root : i64 (compiler-driver-arena-owner-root handle)]
    (if (= root 0)
      0
      (let
        [head : i64
          (unsafe
            (ptr-read (ptr-offset (int->ptr root : (Ptr i64)) 7)))]
        (if (= head 0)
          root
          head)))))

(define (compiler-driver-restore-arena-owner-current! [return-arena : i64]) : unit
  (let
    [active : i64 (arena.tl_arena_current)]
    [active-root : i64 (compiler-driver-arena-owner-root active)]
    [return-root : i64 (compiler-driver-arena-owner-root return-arena)]
    ;; The frontend return handle can name the caller arena's old root while
    ;; optimizer/backend output has advanced that same owner by several
    ;; segments. Preserve an already-active head, or resume the owner's
    ;; root-tracked current head when another arena is active. Re-entering the
    ;; stale root would create a sibling chain that batch destruction cannot
    ;; reach.
    (if (and (not (= active-root 0)) (= active-root return-root))
      unit
      (unsafe
        (arena.tl_arena_set
          (compiler-driver-arena-owner-current-head return-arena))))))

(define (compiler-driver-restore-frontend-return-arena!) : unit
  (if (= compiler-driver-pending-frontend-return-arena 0)
    unit
    (let
      [return-arena : i64 compiler-driver-pending-frontend-return-arena]
      (begin
        (set! compiler-driver-pending-frontend-return-arena 0)
        (compiler-driver-restore-arena-owner-current! return-arena)))))

(define (compiler-driver-retirement-clone-shells? [opt-level : i64]) : bool
  (and
    (>= opt-level 1)
    (not (= compiler-driver-pending-retired-source-arena 0))))

(define (compiler-driver-retire-frontend-arena!) : unit
  (if (= compiler-driver-pending-retired-frontend-arena 0)
    unit
    (let
      [retained-arena : i64 (arena.tl_arena_current)]
      [retire-arena : i64 compiler-driver-pending-retired-frontend-arena]
      (unsafe
        (begin
          (set! compiler-driver-pending-retired-frontend-arena 0)
          (arena.tl_arena_destroy retire-arena)
          (arena.tl_arena_set retained-arena))))))

(define (compiler-driver-retire-lowered-source-arena!) : unit
  (if (= compiler-driver-pending-retired-source-arena 0)
    unit
    (let
      [retained-arena : i64 (arena.tl_arena_current)]
      [retire-arena : i64 compiler-driver-pending-retired-source-arena]
      [retire-expr-storage-arena : i64
        compiler-driver-pending-retired-source-expr-storage-arena]
      [retire-type-storage-arena : i64
        compiler-driver-pending-retired-source-type-storage-arena]
      (begin
        ;; Clear globals at the outer emit boundary, after the load/lower call
        ;; has returned and no active frame can still hold their arena values.
        (compiler-driver-state-clear-pool-backed-caches!)
        (lower-reset-file-state!)
        (unsafe
          (begin
            (set! compiler-driver-pending-retired-source-arena 0)
            (set! compiler-driver-pending-retired-source-expr-storage-arena 0)
            (set! compiler-driver-pending-retired-source-type-storage-arena 0)
            (ast-node-pool-storage-arenas-destroy!
              retire-expr-storage-arena
              retire-type-storage-arena
              retire-arena)
            (arena.tl_arena_destroy retire-arena)
            (arena.tl_arena_set retained-arena)))))))

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
    [(ResultCompilerDriverLowered.Ok program spans pools profile-state)
      (let
        [_profile-program-start : unit
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase profile-state)
            unit)]
        [emit-program : CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler-ir-clone-program-shell pools program)
            program)]
        [_profile-program-finish : unit
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              profile-state
              "retain.program")
            unit)]
        [_profile-spans-start : unit
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase profile-state)
            unit)]
        [emit-spans : CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [_profile-spans-finish : unit
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase profile-state "retain.spans")
            unit)]
        [out : ResultCompilerDriver
          (begin
            (ast-node-pool-reader-use! pools)
            (cfg
              compile-profile
              (compiler-driver-profile-start-phase profile-state))
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase
                profile-state
                "retain.release"))
            (compiler-driver-emit-lowered-with-level-mode-entry-and-crt-and-profile-state
              pools
              input-path
              emit-program
              emit-spans
              target
              has-target
              mode
              opt-level
              emit-entry
              crt-entry
              profile-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriver.Err diag))]))

(define (compiler-driver-emit-lowered-result-buffer-with-level-mode-and-entry
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]) : ResultCompilerDriverBuffer
  (match lowered
    [(ResultCompilerDriverLowered.Ok program spans pools profile-state)
      (let
        [_profile-program-start : unit
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase profile-state)
            unit)]
        [emit-program : CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler-ir-clone-program-shell pools program)
            program)]
        [_profile-program-finish : unit
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              profile-state
              "retain.program")
            unit)]
        [_profile-spans-start : unit
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase profile-state)
            unit)]
        [emit-spans : CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [_profile-spans-finish : unit
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase profile-state "retain.spans")
            unit)]
        [out : ResultCompilerDriverBuffer
          (begin
            (ast-node-pool-reader-use! pools)
            (cfg
              compile-profile
              (compiler-driver-profile-start-phase profile-state))
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase
                profile-state
                "retain.release"))
            (compiler-driver-emit-lowered-buffer-with-level-mode-entry-and-crt-and-profile-state
              pools
              input-path
              emit-program
              emit-spans
              target
              has-target
              mode
              opt-level
              emit-entry
              false
              profile-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriverBuffer.Err diag))]))

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
    [(ResultCompilerDriverLowered.Ok program spans pools profile-state)
      (let
        [emit-program : CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler-ir-clone-program-shell pools program)
            program)]
        [emit-spans : CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerDriverObject
          (begin
            (ast-node-pool-reader-use! pools)
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt-and-profile-state
              pools
              input-path
              emit-program
              emit-spans
              target
              has-target
              mode
              opt-level
              emit-entry
              crt-entry
              profile-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriverObject.Err diag))]))

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
    [(ResultCompilerDriverLowered.Ok program spans pools profile-state)
      (let
        [emit-program : CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler-ir-clone-program-shell pools program)
            program)]
        [emit-spans : CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerDriverPic
          (begin
            (ast-node-pool-reader-use! pools)
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-driver-emit-lowered-pic-with-level-mode-entry-and-crt-and-profile-state
              pools
              input-path
              emit-program
              emit-spans
              target
              has-target
              mode
              opt-level
              emit-entry
              crt-entry
              profile-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriverPic.Err diag))]))

;; The implicit prelude prepended before every entry program. Its runtime and
;; macro roots are loaded as files:
;;   - stdlib/runtime.tl  - fault/abort handlers + OS primitives,
;;     exported as fixed symbols; kept as reachability roots.
;;   - stdlib/core_macros.tl - the implicit core macro prelude: `and`,
;;     `or`, `when`, `unless`, `cond`. Loaded right after runtime so its macros
;;     are source-order visible to the entry and resolve as bare unqualified
;;     calls via the prelude fallback in `macro-call-decl`.
;;     It also loads `stdlib.clone`; the late typed clone-helper handoff calls
;;     that declaration macro by its hygienic canonical identity.
;; Loading the prelude first lets the entry's own (possibly transitive) imports
;; dedup against it before the decls/paths/modules are concatenated.
(cfg
  embedded-stdlib-tlci
  (defenum CompilerDriverPreludeSurface
    (Missing)
    (Ok AstDeclList AstDeclPathList AstDeclModuleList sym_i64_env.SymI64Env)))

(cfg
  embedded-stdlib-tlci
  (define (compiler-driver-cfg-bindings-match?
    [left : sym_i64_env.SymI64Env]
    [right : sym_i64_env.SymI64Env]) : bool
    (let
      [cursor : sym_i64_env.SymI64Env left]
      (begin
        (while true
          (match (sym_i64_env.sym-i64-view cursor)
            [(sym_i64_env.SymI64ViewNil) (return true)]
            [(sym_i64_env.SymI64ViewBind key value rest)
              (if (= key compiler-parse-state-marker-id)
                (set! cursor rest)
                (if (and
                  (sym_i64_env.sym-i64-contains-id right key)
                  (= value (sym_i64_env.sym-i64-lookup-id-or right key -1)))
                  (set! cursor rest)
                  (return false)))]))
        false))))

(cfg
  embedded-stdlib-tlci
  (define (compiler-driver-cfgs-match-default?
    [actual : sym_i64_env.SymI64Env]
    [target : CompilerBackendTarget]) : bool
    (let
      [expected : sym_i64_env.SymI64Env
        (compiler-driver-target-cfgs target (compiler-cfg-empty))]
      (and
        (compiler-driver-cfg-bindings-match? actual expected)
        (compiler-driver-cfg-bindings-match? expected actual)))))

(cfg
  embedded-stdlib-tlci
  (define (compiler-driver-prelude-surface-configuration
    [cfgs : sym_i64_env.SymI64Env]) : String
    (cond
      [(compiler-driver-cfgs-match-default? cfgs (CompilerBackendTarget.Linux))
        "linux-default"]
      [(compiler-driver-cfgs-match-default?
          cfgs
          (CompilerBackendTarget.Windows))
        "windows-default"]
      [else ""])))

(cfg
  embedded-stdlib-tlci
  (define (compiler-driver-prelude-surface-key-valid?
    [key : surface_identity.SurfaceIdentityKey]
    [outer-build : String]
    [expected-source-hash : String]
    [configuration : String]) : bool
    (and
      (string.eq (struct-get key package-name) "stdlib.prelude")
      (string.eq (struct-get key compiler-build) outer-build)
      (string.eq (struct-get key configuration) configuration)
      (> (string.string-length expected-source-hash) 0)
      (string.eq (struct-get key source-hash) expected-source-hash))))

(cfg
  embedded-stdlib-tlci
  (define (compiler-driver-hydrate-prelude-rodata
    [outer-build : String]
    [expected-source-hash : String]
    [rodata : (Array u8)]
    [configuration : String]
    [pools : AstNodePoolContext]) : CompilerDriverPreludeSurface
    (match (tlci-producer-identity-admit
      outer-build
      build_identity.compiler-build-git-hash)
      [(TlciProducerIdentityAdmission.ExactMatch)
        (match (compiler-surface-key rodata)
          [(ResultCompilerSurfaceKey.Missing)
            CompilerDriverPreludeSurface.Missing]
          [(ResultCompilerSurfaceKey.Err _)
            CompilerDriverPreludeSurface.Missing]
          [(ResultCompilerSurfaceKey.Ok key)
            (if (not
              (compiler-driver-prelude-surface-key-valid?
                key
                outer-build
                expected-source-hash
                configuration))
              CompilerDriverPreludeSurface.Missing
              (match (compiler-surface-hydrate rodata key pools)
                [(ResultCompilerSurfaceHydration.Missing)
                  CompilerDriverPreludeSurface.Missing]
                [(ResultCompilerSurfaceHydration.KeyMismatch _)
                  CompilerDriverPreludeSurface.Missing]
                [(ResultCompilerSurfaceHydration.Err _)
                  CompilerDriverPreludeSurface.Missing]
                [(ResultCompilerSurfaceHydration.Ok hydration)
                  (let
                    [ast : SurfaceAstHydration (struct-get hydration ast)]
                    (CompilerDriverPreludeSurface.Ok
                      (struct-get ast decls)
                      (struct-get ast paths)
                      (struct-get ast modules)
                      (struct-get ast seen)))]))])]
      [_ CompilerDriverPreludeSurface.Missing])))

(cfg
  embedded-stdlib-tlci
  (define (compiler-driver-try-hydrate-runtime-prelude
    [stdlib-roots : svec.Vec]
    [cfgs : sym_i64_env.SymI64Env]
    [pools : AstNodePoolContext]
    [surface-arena : i64]) : CompilerDriverPreludeSurface
    (let
      [configuration : String
        (compiler-driver-prelude-surface-configuration cfgs)]
      (if (or
        (= surface-arena 0)
        (compiler-load-stdlib-root-configured? stdlib-roots)
        (= (string.string-length configuration) 0))
        CompilerDriverPreludeSurface.Missing
        (let
          [previous-arena : i64 (arena.tl_arena_current)]
          [_set-surface-arena : unit
            (unsafe
              (arena.tl_arena_set surface-arena))]
          [result : CompilerDriverPreludeSurface
            (match (compiler-embedded-stdlib-tlci-surface)
              [(CompilerEmbeddedStdlibTlciSurface.Unavailable _)
                CompilerDriverPreludeSurface.Missing]
              [(CompilerEmbeddedStdlibTlciSurface.Ok
                  outer-build
                  source-hash
                  rodata)
                (compiler-driver-hydrate-prelude-rodata
                  outer-build
                  source-hash
                  rodata
                  configuration
                  pools)])]
          (begin
            (unsafe
              (arena.tl_arena_set previous-arena))
            result))))))

(define (compiler-driver-note-prelude-source-pipeline!) : unit
  (cfg
    compile-profile
    (set!
      compiler-driver-profile-prelude-source-pipeline-entries
      (+ compiler-driver-profile-prelude-source-pipeline-entries 1))
    unit))

(define (compiler-driver-load-runtime-prelude-cold
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (begin
    (compiler-driver-note-prelude-source-pipeline!)
    (match (compiler-load-stdlib-prelude-file-with-roots-cfg
      compiler-load-runtime-prelude-path
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
        (ResultCompilerLoadWithPaths.Err diag)])))

(define (compiler-driver-load-runtime-prelude-cache-miss
  [key : CompilerLoadPreludeCacheKey]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [prev-arena : i64 (arena.tl_arena_current)]
    [loaded : ResultCompilerLoadWithPaths
      (begin
        (unsafe
          (arena.tl_arena_set node-pool-base-arena))
        (let
          [persistent-key : CompilerLoadPreludeCacheKey
            (compiler-load-prelude-cache-key-copy key)]
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
      [key : CompilerLoadPreludeCacheKey
        (compiler-load-runtime-prelude-cache-key stdlib-roots cfgs)]
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
  [load-state : CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (begin
    (compiler-driver-note-prelude-source-pipeline!)
    (match (compiler-load-stdlib-prelude-file-with-roots-cfg-with-pools
      load-state
      compiler-load-runtime-prelude-path
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
          load-state
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
        (ResultCompilerLoadWithPaths.Err diag)])))

(define (compiler-driver-load-runtime-prelude-cache-miss-with-state-and-pools
  [load-state : CompilerLoadSessionState]
  [key : CompilerLoadPreludeCacheKey]
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
          [persistent-key : CompilerLoadPreludeCacheKey
            (compiler-load-prelude-cache-key-copy key)]
          [cold : ResultCompilerLoadWithPaths
            (compiler-driver-load-runtime-prelude-cold-with-pools
              load-state
              stdlib-roots
              cfgs
              pools)]
          (begin
            (match cold
              [(ResultCompilerLoadWithPaths.Ok decls paths modules seen)
                (compiler-driver-runtime-prelude-cache-store-with-state-and-pools
                  load-state
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

(define (compiler-driver-load-runtime-prelude-ordinary-with-state-and-pools
  [load-state : CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (if (compiler-load-session-state-cache-enabled? load-state)
    (let
      [key : CompilerLoadPreludeCacheKey
        (compiler-load-session-state-runtime-prelude-cache-key
          load-state
          stdlib-roots
          cfgs)]
      (match (compiler-driver-runtime-prelude-cache-lookup-with-state
        load-state
        key)
        [(CompilerLoadPreludeCacheHit decls paths modules seen)
          (ResultCompilerLoadWithPaths.Ok decls paths modules seen)]
        [(CompilerLoadPreludeCacheMiss)
          (compiler-driver-load-runtime-prelude-cache-miss-with-state-and-pools
            load-state
            key
            stdlib-roots
            cfgs
            pools)]))
    (compiler-driver-load-runtime-prelude-cold-with-pools
      load-state
      stdlib-roots
      cfgs
      pools)))

(define (compiler-driver-load-runtime-prelude-with-state-pools-and-surface
  [load-state : CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  ;; lint-allow: unused-variable -- used by embedded-stdlib-tlci builds.
  [surface-arena : i64]) : ResultCompilerLoadWithPaths
  (cfg
    embedded-stdlib-tlci
    (let
      [_surface-begin : unit
        (cfg
          compile-startup-profile
          (startup_profile.compiler-startup-profile-mark-surface-begin!)
          unit)]
      [surface : CompilerDriverPreludeSurface
        (compiler-driver-try-hydrate-runtime-prelude
          stdlib-roots
          cfgs
          pools
          surface-arena)]
      [_surface-end : unit
        (cfg
          compile-startup-profile
          (startup_profile.compiler-startup-profile-mark-surface-end!)
          unit)]
      (match surface
        [(CompilerDriverPreludeSurface.Missing)
          (compiler-driver-load-runtime-prelude-ordinary-with-state-and-pools
            load-state
            stdlib-roots
            cfgs
            pools)]
        [(CompilerDriverPreludeSurface.Ok decls paths modules seen)
          (begin
            ;; Hydration bypasses the ordinary stdlib source loader, so record
            ;; the embedded provenance that loader would have attached. Macro
            ;; routing must not depend on an unrelated later import happening
            ;; to resolve core_macros.tl from the embedded payload.
            (compiler-load-note-embedded-module!
              compiler-load-core-macro-prelude-path)
            (compiler-load-note-embedded-module!
              compiler-load-runtime-prelude-path)
            (compiler-load-session-state-note-embedded-stdlib-source!
              load-state)
            (cfg
              compile-profile
              (set!
                compiler-driver-profile-prelude-hydrations
                (+ compiler-driver-profile-prelude-hydrations 1))
              unit)
            (ResultCompilerLoadWithPaths.Ok decls paths modules seen))]))
    (compiler-driver-load-runtime-prelude-ordinary-with-state-and-pools
      load-state
      stdlib-roots
      cfgs
      pools)))

(define (compiler-driver-load-runtime-prelude-with-state-and-pools
  [load-state : CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-driver-load-runtime-prelude-with-state-pools-and-surface
    load-state
    stdlib-roots
    cfgs
    pools
    0))

(define (compiler-driver-load-file-with-runtime-with-state-pools-and-surface
  [load-state : CompilerLoadSessionState]
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [surface-arena : i64]) : ResultCompilerLoadWithPaths
  (let
    [_prelude-begin : unit
      (cfg
        compile-startup-profile
        (startup_profile.compiler-startup-profile-mark-prelude-begin!)
        unit)]
    [prelude : ResultCompilerLoadWithPaths
      (compiler-driver-load-runtime-prelude-with-state-pools-and-surface
        load-state
        stdlib-roots
        cfgs
        pools
        surface-arena)]
    [_prelude-end : unit
      (cfg
        compile-startup-profile
        (startup_profile.compiler-startup-profile-mark-prelude-end!)
        unit)]
    (match prelude
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (begin
          (cfg
            compile-startup-profile
            (startup_profile.compiler-startup-profile-mark-user-entry-start!)
            unit)
          (match (compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
            load-state
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
              (ResultCompilerLoadWithPaths.Err diag)]))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (ResultCompilerLoadWithPaths.Err diag)])))

(define (compiler-driver-load-source-with-runtime-with-state-and-pools
  [load-state : CompilerLoadSessionState]
  [input-path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-driver-load-runtime-prelude-with-state-and-pools
    load-state
    stdlib-roots
    cfgs
    pools)
    [(ResultCompilerLoadWithPaths.Ok
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
        load-state
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

(define (compiler-driver-load-source-with-runtime-with-pools
  [input-path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-driver-load-source-with-runtime-with-state-and-pools
    compiler-load-active-session-state
    input-path
    source
    stdlib-roots
    cfgs
    pools))

(define (compiler-driver-load-file-for-pic-image-with-pools
  [load-state : CompilerLoadSessionState]
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-load-core-macro-prelude-with-roots-cfg-with-pools
    load-state
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
        load-state
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

(define (compiler-driver-load-and-lower-escaping-and-profile-state
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverLowered
  (match (compiler-driver-load-file-with-runtime input-path stdlib-roots cfgs)
    [(ResultCompilerLoadWithPaths.Ok decls paths modules _)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase profile-state "load"))
        (cfg
          compile-profile
          (compiler-driver-profile-start-phase profile-state))
        (match (lower-compiler-program-with-decl-paths-mode-cache
          input-path
          (ast-program decls)
          (ast-decl-path-list-with-modules paths modules)
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
                (compiler-driver-profile-finish-phase profile-state "lower"))
              (if (ast-node-pool-reader-type-exhausted?)
                (ResultCompilerDriverLowered.Err
                  (box
                    (compiler-driver-ty-node-pool-exhausted-diagnostic
                      input-path)))
                (compiler-driver-lowered-from-active-pools-and-profile-state
                  program
                  spans
                  profile-state)))]
          [(ResultCompilerLower.Err diag)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase profile-state "lower"))
              (ResultCompilerDriverLowered.Err diag))]))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase profile-state "load"))
        (ResultCompilerDriverLowered.Err diag))]))

(define (compiler-driver-load-and-lower-escaping
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverLowered
  (compiler-driver-load-and-lower-escaping-and-profile-state
    input-path
    target
    stdlib-roots
    mode
    cfgs
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-load-and-lower-pic-image-and-profile-state
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverLowered
  (match (compiler-driver-load-file-for-pic-image input-path stdlib-roots cfgs)
    [(ResultCompilerLoadWithPaths.Ok decls paths modules _)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase profile-state "load"))
        (cfg
          compile-profile
          (compiler-driver-profile-start-phase profile-state))
        (match (lower-compiler-program-with-decl-paths-mode-cache
          input-path
          (ast-program decls)
          (ast-decl-path-list-with-modules paths modules)
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
                (compiler-driver-profile-finish-phase profile-state "lower"))
              (if (ast-node-pool-reader-type-exhausted?)
                (ResultCompilerDriverLowered.Err
                  (box
                    (compiler-driver-ty-node-pool-exhausted-diagnostic
                      input-path)))
                (compiler-driver-lowered-from-active-pools-and-profile-state
                  program
                  spans
                  profile-state)))]
          [(ResultCompilerLower.Err diag)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase profile-state "lower"))
              (ResultCompilerDriverLowered.Err diag))]))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase profile-state "load"))
        (ResultCompilerDriverLowered.Err diag))]))

(define (compiler-driver-load-and-lower-pic-image
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverLowered
  (compiler-driver-load-and-lower-pic-image-and-profile-state
    input-path
    target
    stdlib-roots
    mode
    cfgs
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-load-and-lower-escaping-with-state-and-retirement
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [retire-after-lower? : bool]) : ResultCompilerDriverLowered
  (let
    [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
    [release-source-pools? : bool
      (compiler-driver-state-can-release-checked-lower-source-pools? state)]
    [route-source-allocations? : bool
      (and release-source-pools? retire-after-lower?)]
    [frontend-arena : i64
      (if route-source-allocations?
        (arena.tl_arena_make)
        0)]
    [_use-frontend-arena : unit
      (if route-source-allocations?
        (begin
          (set!
            compiler-driver-pending-frontend-return-arena
            (arena.tl_arena_current))
          (unsafe
            (arena.tl_arena_set frontend-arena)))
        unit)]
    [_install-interns : unit (compiler-driver-state-install-interns! state)]
    [parser-state : CompilerParseState (struct-get state parser-state)]
    [_reset-type-literal-tracking : unit
      (compiler-parse-state-type-literal-reset! parser-state)]
    [parse-cfgs : sym_i64_env.SymI64Env
      (compiler-parse-state-cfgs parser-state cfgs)]
    (match (compiler-driver-load-file-with-runtime-with-state-pools-and-surface
      (struct-get state load-session)
      input-path
      stdlib-roots
      parse-cfgs
      pools
      (compiler-driver-state-surface-arena state))
      [(ResultCompilerLoadWithPaths.Ok decls paths modules _)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (compiler-driver-state-profile state)
              "load"))
          (cfg compile-profile (compiler-driver-profile-prelude-counters))
          (compiler-driver-allocation-profile-snapshot! "load")
          (compiler-driver-allocation-profile-pool-storage-snapshot!
            "source-load"
            pools)
          (cfg
            compile-profile
            (compiler-lower-profile-pools "source_load" pools)
            unit)
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase
              (compiler-driver-state-profile state)))
          ;; Parsing initialized builtin IDs for this state's active intern
          ;; table. Preserve that snapshot instead of reinstalling the stale
          ;; pre-parse builtin state; only lowerer arenas need restoration here.
          (compiler-driver-state-capture-active-builtins! state)
          (compiler-driver-state-install-lower-arenas! state)
          (compiler-driver-state-install-pools! state)
          (let
            [_capture-source-names : unit
              (compiler-driver-state-capture-active-interns! state)]
            [source-names : ci.InternSourceNameSessionHandle
              (ci.intern-source-name-session-handle
                (ci.intern-source-name-session-from-state
                  (compiler-driver-state-owned-interns state)))]
            [defer-source-destroy? : bool
              (and
                release-source-pools?
                (compiler-parse-state-has-type-literal? parser-state))]
            [dest-pools : AstNodePoolContext
              (if release-source-pools?
                (compiler-driver-state-new-checked-lower-pools)
                pools)]
            [_profile-checked-storage : unit
              (begin
                (compiler-driver-allocation-profile-pool-storage-snapshot!
                  "checked-pool"
                  dest-pools)
                (cfg
                  compile-profile
                  (compiler-lower-profile-pools "checked_pool" dest-pools)
                  unit))]
            [entry-arena : i64 (arena.tl_arena_current)]
            ;; Release the source pools from the newest segment of their arena
            ;; chain, not the make() root handle: the chain is reachable only from
            ;; its head, so destroying the root leaks every overflow segment (the
            ;; whole-program parsed AST), which accumulates across batch entries.
            [source-pools-arena : i64 (ast-node-pool-context-base-arena pools)]
            ;; `compiler-driver-state-adopt-pools!` mutates the state's shared
            ;; cells. Preserve the retiring storage handles before adoption so
            ;; the type-literal deferred path cannot mistake the new pool for
            ;; its source and unmap live segments.
            [source-expr-storage-arena : i64
              (ast-node-pool-context-expr-storage-arena pools)]
            [source-type-storage-arena : i64
              (ast-node-pool-context-type-storage-arena pools)]
            [_clear-source-floors : unit
              (if release-source-pools?
                (compiler-load-session-state-floors-set!
                  (struct-get state load-session)
                  0
                  0
                  0)
                unit)]
            [_arm-release : unit
              (if release-source-pools?
                (compiler-lower-checked-dest-pools-use!
                  dest-pools
                  (if defer-source-destroy?
                    0
                    source-pools-arena)
                  (if defer-source-destroy?
                    0
                    (ast-node-pool-context-expr-storage-arena pools))
                  (if defer-source-destroy?
                    0
                    (ast-node-pool-context-type-storage-arena pools))
                  (if (and
                    route-source-allocations?
                    (not defer-source-destroy?))
                    frontend-arena
                    0))
                (compiler-lower-checked-dest-pools-clear!))]
            [lowered : ResultCompilerLower
              (lower-compiler-program-with-decl-paths-mode-cache-and-pools-and-source-names-and-load-state
                (struct-get state load-session)
                (struct-get state typecheck-prefix-cache)
                (struct-get state typecheck-state)
                input-path
                (ast-program decls)
                (ast-decl-path-list-with-modules paths modules)
                (compiler-driver-lower-mode-for-target target mode)
                stdlib-roots
                (compiler-load-prelude-cache-key
                  "typecheck-prefix-lower"
                  stdlib-roots
                  cfgs)
                pools
                source-names)]
            [dest-committed? : bool
              (compiler-lower-checked-dest-pools-committed?)]
            [frontend-released? : bool
              (compiler-lower-checked-frontend-released?)]
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
                (begin
                  (compiler-lower-checked-dest-pools-abort-uncommitted!)
                  (compiler-driver-state-destroy-uncommitted-pools! dest-pools))
                unit)]
            [_destroy-deferred-source : unit
              (if (and defer-source-destroy? dest-committed?)
                (begin
                  (compiler-typecheck-ctfe-env-cache-clear!)
                  (ast-node-pool-storage-arenas-destroy!
                    source-expr-storage-arena
                    source-type-storage-arena
                    source-pools-arena)
                  (unsafe
                    (arena.tl_arena_destroy source-pools-arena)))
                unit)]
            [_restore-entry-arena : unit
              (if release-source-pools?
                (unsafe
                  (arena.tl_arena_set
                    (if frontend-released?
                      compiler-driver-pending-frontend-return-arena
                      (if (and
                        dest-committed?
                        (= entry-arena source-pools-arena))
                        (ast-node-pool-context-base-arena result-pools)
                        entry-arena))))
                unit)]
            [_clear-release : unit (compiler-lower-checked-dest-pools-clear!)]
            (match lowered
              [(ResultCompilerLower.Ok program spans)
                (begin
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase
                      (compiler-driver-state-profile state)
                      "lower"))
                  (compiler-driver-allocation-profile-pool-storage-snapshot!
                    "macro-detach"
                    result-pools)
                  (cfg
                    compile-profile
                    (compiler-lower-profile-pools "macro_detach" result-pools)
                    unit)
                  (compiler-driver-state-prefix-cache-allocation-profile-snapshot!
                    state
                    "lower")
                  (compiler-driver-allocation-profile-snapshot! "lower")
                  (if (ast-node-pool-context-type-exhausted? pools)
                    (ResultCompilerDriverLowered.Err
                      (box
                        (compiler-driver-ty-node-pool-exhausted-diagnostic
                          input-path)))
                    (if (and dest-committed? retire-after-lower?)
                      (begin
                        (if (and
                          route-source-allocations?
                          (not frontend-released?))
                          (begin
                            ;; Keep front-end storage alive until the outer
                            ;; result adapter has cloned program shells/spans
                            ;; and persisted interned strings. Return allocation
                            ;; to the caller-owned arena so the optimizer's
                            ;; escaped output does not share either retiring
                            ;; frontend or checked-pool storage.
                            (set!
                              compiler-driver-pending-retired-frontend-arena
                              (arena.tl_arena_current))
                            (unsafe
                              (arena.tl_arena_set
                                compiler-driver-pending-frontend-return-arena)))
                          unit)
                        (compiler-driver-state-retain-lowered-types!
                          state
                          program
                          spans
                          result-pools))
                      (compiler-driver-lowered-from-pools-and-profile-state
                        program
                        spans
                        result-pools
                        (compiler-driver-state-profile state)))))]
              [(ResultCompilerLower.Err diag)
                (begin
                  ;; A lower-phase failure can leave the state's checked pool
                  ;; storage already retired by the checked-lower choreography
                  ;; (the rollover/commit paths retire source storage during
                  ;; macro expansion). Re-own a fresh, live pool context so the
                  ;; batch/file release path never retires that dead storage
                  ;; again. Refs #5448.
                  (if release-source-pools?
                    (compiler-driver-state-adopt-pools!
                      state
                      (compiler-driver-state-new-checked-lower-pools))
                    unit)
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase
                      (compiler-driver-state-profile state)
                      "lower"))
                  (compiler-driver-state-prefix-cache-allocation-profile-snapshot!
                    state
                    "lower")
                  (compiler-driver-allocation-profile-snapshot! "lower")
                  (ResultCompilerDriverLowered.Err diag))])))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (compiler-driver-state-profile state)
              "load"))
          (compiler-driver-allocation-profile-snapshot! "load")
          (ResultCompilerDriverLowered.Err diag))])))

(define (compiler-driver-load-and-lower-pic-image-with-state-and-retirement
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [retire-after-lower? : bool]) : ResultCompilerDriverLowered
  (let
    [pools : AstNodePoolContext (compiler-driver-state-pool-context state)]
    [_install-interns : unit (compiler-driver-state-install-interns! state)]
    [parser-state : CompilerParseState (struct-get state parser-state)]
    [_reset-type-literal-tracking : unit
      (compiler-parse-state-type-literal-reset! parser-state)]
    [parse-cfgs : sym_i64_env.SymI64Env
      (compiler-parse-state-cfgs parser-state cfgs)]
    (match (compiler-driver-load-file-for-pic-image-with-pools
      (struct-get state load-session)
      input-path
      stdlib-roots
      parse-cfgs
      pools)
      [(ResultCompilerLoadWithPaths.Ok decls paths modules _)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (compiler-driver-state-profile state)
              "load"))
          (compiler-driver-allocation-profile-pool-storage-snapshot!
            "source-load"
            pools)
          (cfg
            compile-profile
            (compiler-lower-profile-pools "source_load" pools)
            unit)
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase
              (compiler-driver-state-profile state)))
          (compiler-driver-state-capture-active-builtins! state)
          (compiler-driver-state-install-lower-arenas! state)
          (compiler-driver-state-install-pools! state)
          (let
            [_capture-source-names : unit
              (compiler-driver-state-capture-active-interns! state)]
            [source-names : ci.InternSourceNameSessionHandle
              (ci.intern-source-name-session-handle
                (ci.intern-source-name-session-from-state
                  (compiler-driver-state-owned-interns state)))]
            [release-source-pools? : bool
              (compiler-driver-state-can-release-checked-lower-source-pools?
                state)]
            [defer-source-destroy? : bool
              (and
                release-source-pools?
                (compiler-parse-state-has-type-literal? parser-state))]
            [dest-pools : AstNodePoolContext
              (if release-source-pools?
                (compiler-driver-state-new-checked-lower-pools)
                pools)]
            [_profile-checked-storage : unit
              (begin
                (compiler-driver-allocation-profile-pool-storage-snapshot!
                  "checked-pool"
                  dest-pools)
                (cfg
                  compile-profile
                  (compiler-lower-profile-pools "checked_pool" dest-pools)
                  unit))]
            [entry-arena : i64 (arena.tl_arena_current)]
            ;; Release the source pools from the newest segment of their arena
            ;; chain, not the make() root handle: the chain is reachable only from
            ;; its head, so destroying the root leaks every overflow segment (the
            ;; whole-program parsed AST), which accumulates across batch entries.
            [source-pools-arena : i64 (ast-node-pool-context-base-arena pools)]
            ;; These must remain source identities after the state cells adopt
            ;; the compacted destination below.
            [source-expr-storage-arena : i64
              (ast-node-pool-context-expr-storage-arena pools)]
            [source-type-storage-arena : i64
              (ast-node-pool-context-type-storage-arena pools)]
            [_clear-source-floors : unit
              (if release-source-pools?
                (compiler-load-session-state-floors-set!
                  (struct-get state load-session)
                  0
                  0
                  0)
                unit)]
            [_arm-release : unit
              (if release-source-pools?
                (compiler-lower-checked-dest-pools-use!
                  dest-pools
                  (if defer-source-destroy?
                    0
                    source-pools-arena)
                  (if defer-source-destroy?
                    0
                    (ast-node-pool-context-expr-storage-arena pools))
                  (if defer-source-destroy?
                    0
                    (ast-node-pool-context-type-storage-arena pools))
                  0)
                (compiler-lower-checked-dest-pools-clear!))]
            [lowered : ResultCompilerLower
              (lower-compiler-program-with-decl-paths-mode-cache-and-pools-and-source-names-and-load-state
                (struct-get state load-session)
                (struct-get state typecheck-prefix-cache)
                (struct-get state typecheck-state)
                input-path
                (ast-program decls)
                (ast-decl-path-list-with-modules paths modules)
                (compiler-driver-lower-mode-for-target target mode)
                stdlib-roots
                (compiler-load-prelude-cache-key
                  "typecheck-prefix-lower"
                  stdlib-roots
                  cfgs)
                pools
                source-names)]
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
                (begin
                  (compiler-lower-checked-dest-pools-abort-uncommitted!)
                  (compiler-driver-state-destroy-uncommitted-pools! dest-pools))
                unit)]
            [_destroy-deferred-source : unit
              (if (and defer-source-destroy? dest-committed?)
                (begin
                  (compiler-typecheck-ctfe-env-cache-clear!)
                  (ast-node-pool-storage-arenas-destroy!
                    source-expr-storage-arena
                    source-type-storage-arena
                    source-pools-arena)
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
                    (compiler-driver-profile-finish-phase
                      (compiler-driver-state-profile state)
                      "lower"))
                  (compiler-driver-allocation-profile-pool-storage-snapshot!
                    "macro-detach"
                    result-pools)
                  (cfg
                    compile-profile
                    (compiler-lower-profile-pools "macro_detach" result-pools)
                    unit)
                  (if (ast-node-pool-context-type-exhausted? pools)
                    (ResultCompilerDriverLowered.Err
                      (box
                        (compiler-driver-ty-node-pool-exhausted-diagnostic
                          input-path)))
                    (if (and dest-committed? retire-after-lower?)
                      (compiler-driver-state-retain-lowered-types!
                        state
                        program
                        spans
                        result-pools)
                      (compiler-driver-lowered-from-pools-and-profile-state
                        program
                        spans
                        result-pools
                        (compiler-driver-state-profile state)))))]
              [(ResultCompilerLower.Err diag)
                (begin
                  ;; See the matching note in
                  ;; compiler-driver-load-and-lower-escaping-with-state-and-retirement:
                  ;; a lower-phase failure can leave checked pool storage
                  ;; already retired; re-own a live context before release.
                  ;; Refs #5448.
                  (if release-source-pools?
                    (compiler-driver-state-adopt-pools!
                      state
                      (compiler-driver-state-new-checked-lower-pools))
                    unit)
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase
                      (compiler-driver-state-profile state)
                      "lower"))
                  (ResultCompilerDriverLowered.Err diag))])))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (compiler-driver-state-profile state)
              "load"))
          (ResultCompilerDriverLowered.Err diag))])))

(define (compiler-driver-load-and-lower-pic-image-with-state
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverLowered
  (compiler-driver-load-and-lower-pic-image-with-state-and-retirement
    state
    input-path
    target
    stdlib-roots
    mode
    cfgs
    false))

(define (compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [crt-entry : bool]) : ResultCompilerDriver
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (cfg compile-profile (compiler-driver-profile-start-total profile-state))
      ;; The lowering provenance side table is remapped after
      ;; optimization so backend diagnostics report surviving instruction
      ;; locations when a rewrite can preserve them.
      (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
        input-path
        (compiler-driver-load-and-lower-escaping-and-profile-state
          input-path
          target
          stdlib-roots
          mode
          (compiler-driver-target-cfgs target cfgs)
          profile-state)
        target
        has-target
        mode
        opt-level
        true
        crt-entry))))

(define (compiler-driver-emit-file-buffer-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverBuffer
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (cfg compile-profile (compiler-driver-profile-start-total profile-state))
      (compiler-driver-emit-lowered-result-buffer-with-level-mode-and-entry
        input-path
        (compiler-driver-load-and-lower-escaping-and-profile-state
          input-path
          target
          stdlib-roots
          mode
          (compiler-driver-target-cfgs target cfgs)
          profile-state)
        target
        has-target
        mode
        opt-level
        true))))

(define (compiler-driver-emit-file-object-image-with-target-roots-level-mode-cfg-and-crt
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [crt-entry : bool]) : ResultCompilerDriverObject
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (cfg compile-profile (compiler-driver-profile-start-total profile-state))
      (compiler-driver-emit-lowered-result-object-image-with-level-mode-entry-and-crt
        input-path
        (compiler-driver-load-and-lower-escaping-and-profile-state
          input-path
          target
          stdlib-roots
          mode
          (compiler-driver-target-cfgs target cfgs)
          profile-state)
        target
        has-target
        mode
        opt-level
        true
        crt-entry))))

(define (compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverPic
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (cfg compile-profile (compiler-driver-profile-start-total profile-state))
      (compiler-driver-emit-lowered-result-pic-with-level-mode-entry-and-crt
        input-path
        (compiler-driver-load-and-lower-pic-image-and-profile-state
          input-path
          target
          stdlib-roots
          mode
          (compiler-driver-target-cfgs target cfgs)
          profile-state)
        target
        has-target
        mode
        opt-level
        false
        false))))

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
    (cfg
      compile-profile
      (compiler-driver-profile-start-total
        (compiler-driver-state-profile state)))
    (let
      [lowered : ResultCompilerDriverLowered
        (compiler-driver-load-and-lower-escaping-with-state-and-retirement
          state
          input-path
          target
          stdlib-roots
          mode
          (compiler-driver-state-target-cfgs state target cfgs)
          (>= opt-level 1))]
      (begin
        (compiler-driver-state-install-builtins! state)
        (compiler-driver-emit-lowered-result-buffer-with-level-mode-and-entry
          input-path
          lowered
          target
          has-target
          mode
          opt-level
          true)))))

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
    (cfg
      compile-profile
      (compiler-driver-profile-start-total
        (compiler-driver-state-profile state)))
    (let
      [lowered : ResultCompilerDriverLowered
        (compiler-driver-load-and-lower-pic-image-with-state-and-retirement
          state
          input-path
          target
          stdlib-roots
          mode
          (compiler-driver-state-target-cfgs state target cfgs)
          (>= opt-level 1))]
      (begin
        (compiler-driver-state-install-builtins! state)
        (compiler-driver-emit-lowered-result-pic-with-level-mode-entry-and-crt
          input-path
          lowered
          target
          has-target
          mode
          opt-level
          false
          false)))))

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
  [pools : AstNodePoolContext]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [opt-level : i64]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriver
  (if (ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriver.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic "")))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (compiler-driver-retire-frontend-arena!)
      (match (optimize-program-with-spans-and-pools-and-level-and-profile-state
        pools
        program
        spans
        opt-level
        profile-state)
        [(CompilerOptimizedProgram.Program optimized _)
          (begin
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerDriver.Err
                (box (compiler-driver-ty-node-pool-exhausted-diagnostic "")))
              (ResultCompilerDriver.Ok
                (compiler-driver-ir-summary-render
                  (compiler-ir-program-summary optimized)))))]))))

(define (compiler-driver-emit-ir-summary-lowered-result-with-level
  [lowered : ResultCompilerDriverLowered]
  [opt-level : i64]) : ResultCompilerDriver
  (match lowered
    [(ResultCompilerDriverLowered.Ok program spans pools profile-state)
      (let
        [emit-program : CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler-ir-clone-program-shell pools program)
            program)]
        [emit-spans : CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerDriver
          (begin
            (ast-node-pool-reader-use! pools)
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-driver-emit-ir-summary-lowered-with-level
              pools
              emit-program
              emit-spans
              opt-level
              profile-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriver.Err diag))]))

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

(define (compiler-driver-ir-text-result
  [type-segment-bases : i64]
  [optimized : CompilerIrProgram]
  [dump-pass : String]) : ResultCompilerDriver
  (let
    [verify-error : String (compiler-opt-debug-verification-error)]
    (if (> (string.string-length verify-error) 0)
      (ResultCompilerDriver.Err
        (box
          (compiler-diagnostic-at-start
            ""
            (string.append "IR verification failed: " verify-error))))
      (let
        [text : String
          (if (> (string.string-length dump-pass) 0)
            (compiler-opt-debug-dump-result)
            (compiler-ir-program-render type-segment-bases optimized))]
        (if (and
          (> (string.string-length dump-pass) 0)
          (= (string.string-length text) 0))
          (ResultCompilerDriver.Err
            (box
              (compiler-diagnostic-at-start
                ""
                (str_cat.str-cat "optimizer pass '" dump-pass "' did not run"))))
          (ResultCompilerDriver.Ok text))))))

(define (compiler-driver-emit-ir-text-lowered-with-level
  [pools : AstNodePoolContext]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [opt-level : i64]
  [dump-pass : String]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriver
  (if (ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriver.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic "")))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower!)
      (compiler-driver-retire-frontend-arena!)
      (match (optimize-program-with-spans-and-pools-and-level-and-profile-state
        pools
        program
        spans
        opt-level
        profile-state)
        [(CompilerOptimizedProgram.Program optimized _)
          (begin
            (compiler-driver-release-lowered-ir! opt-level)
            (if (ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerDriver.Err
                (box (compiler-driver-ty-node-pool-exhausted-diagnostic "")))
              (compiler-driver-ir-text-result
                (ast-node-pool-context-type-segment-bases pools)
                optimized
                dump-pass)))]))))

(define (compiler-driver-emit-ir-text-lowered-result-with-level
  [lowered : ResultCompilerDriverLowered]
  [opt-level : i64]
  [dump-pass : String]) : ResultCompilerDriver
  (match lowered
    [(ResultCompilerDriverLowered.Ok program spans pools profile-state)
      (let
        [emit-program : CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler-ir-clone-program-shell pools program)
            program)]
        [emit-spans : CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerDriver
          (begin
            (ast-node-pool-reader-use! pools)
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-driver-emit-ir-text-lowered-with-level
              pools
              emit-program
              emit-spans
              opt-level
              dump-pass
              profile-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriver.Err diag))]))

(define (compiler-driver-state-emit-ir-text-file-with-target-roots-level-mode-and-cfg
  [state : CompilerDriverState]
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [dump-pass : String]) : ResultCompilerDriver
  (compiler-driver-emit-ir-text-lowered-result-with-level
    (compiler-driver-load-and-lower-pic-image-with-state
      state
      input-path
      target
      stdlib-roots
      mode
      (compiler-driver-state-target-cfgs state target cfgs))
    opt-level
    dump-pass))

(define (compiler-driver-write-text-buf
  [output-path : String]
  [buf : text_buf.TextBuf]) : i64
  (text_buf.write-file output-path buf))

;; Human-facing compiler commands render the diagnostic against its primary
;; source file. Keep `compiler-diagnostic-render` as the stable flat form for
;; LSP, public-tool, and other machine-readable consumers.
(define (compiler-driver-render-source-diagnostic [diag : CompilerDiagnostic]) : String
  (let
    [path : String (compiler-diagnostic-path diag)]
    (if (string.eq path "")
      (compiler-diagnostic-render-source diag "")
      (match (io.try-read-file (& path))
        [(io.OkIoString source) (compiler-diagnostic-render-source diag source)]
        [(io.ErrIoString _) (compiler-diagnostic-render-source diag "")]))))

(define (compiler-driver-write-result
  [_profile-state : profile_state.CompilerProfileState]
  [result : ResultCompilerDriver]
  [output-path : String]) : i64
  (match result
    [(ResultCompilerDriver.Ok asm)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-start-phase _profile-state))
        (io.write-file output-path asm)
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase _profile-state "write"))
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total _profile-state))
        (io.print-string
          (string.append "Wrote " (string.append output-path "\n")))
        0)]
    [(ResultCompilerDriver.Err diag)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total _profile-state))
        (io.print-error
          (compiler-driver-render-source-diagnostic (box-get diag)))
        1)]))

(define (compiler-driver-write-buffer-result
  [_profile-state : profile_state.CompilerProfileState]
  [result : ResultCompilerDriverBuffer]
  [output-path : String]) : i64
  (match result
    [(ResultCompilerDriverBuffer.Ok buf)
      (let
        [status : i64
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-start-phase _profile-state))
            (compiler-driver-write-text-buf output-path buf))]
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase _profile-state "write"))
          (compiler-driver-allocation-profile-snapshot! "write")
          (cfg
            compile-profile
            (compiler-driver-profile-finish-total _profile-state))
          (if (= status 0)
            (begin
              (io.print-string
                (string.append "Wrote " (string.append output-path "\n")))
              0)
            status)))]
    [(ResultCompilerDriverBuffer.Err diag)
      (begin
        (compiler-driver-allocation-profile-snapshot! "write-error")
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total _profile-state))
        (io.print-error
          (compiler-driver-render-source-diagnostic (box-get diag)))
        1)]))

(define (compiler-driver-pic-fixups-path [output-path : String]) : String
  (string.append output-path ".fixups"))

(define (compiler-driver-write-pic-result
  [_profile-state : profile_state.CompilerProfileState]
  [result : ResultCompilerDriverPic]
  [output-path : String]) : i64
  (match result
    [(ResultCompilerDriverPic.Ok output)
      (let
        [fixups-path : String (compiler-driver-pic-fixups-path output-path)]
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase _profile-state))
          (io.write-file output-path (struct-get output asm))
          (io.write-file fixups-path (struct-get output fixups))
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase _profile-state "write"))
          (cfg
            compile-profile
            (compiler-driver-profile-finish-total _profile-state))
          (io.print-string
            (string.append "Wrote " (string.append output-path "\n")))
          (io.print-string
            (string.append "Wrote " (string.append fixups-path "\n")))
          0))]
    [(ResultCompilerDriverPic.Err diag)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total _profile-state))
        (io.print-error
          (compiler-driver-render-source-diagnostic (box-get diag)))
        1)]))