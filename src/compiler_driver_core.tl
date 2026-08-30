;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)
(import (vector.vector String) as svec)
(cfg compile-profile (import stdlib.profile))
(cfg test (import stdlib.test))
(import compiler_allocation_profile as allocation_profile)
(import compiler_profile_state as profile_state)
(import compiler_backend)
(import compiler_ast_types)
(import compiler_typecheck_core)
(import compiler_parse_core)
(import compiler_lower)
(import compiler_ir_types)
(import compiler_ctfe)
(import compiler_object as cobj)
(import compiler_builtin_ids as cbi)
(import compiler_target_cfg_core as target_cfg)
(import compiler_diagnostic)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_load)
(cfg embedded-stdlib-tlci (import compiler_build_identity as build_identity))
(cfg
  embedded-stdlib-tlci
  (import compiler_surface_identity as surface_identity))
(cfg embedded-stdlib-tlci (import compiler_surface_ast as surface_ast))
(cfg embedded-stdlib-tlci (import compiler_surface_facts))
(cfg embedded-stdlib-tlci (import compiler_surface_hydrate))
(cfg
  embedded-stdlib-tlci
  (import compiler_embedded_stdlib_tlci as embedded_tlci))
(cfg embedded-stdlib-tlci (import tlci_core as tlci))
(cfg
  compile-startup-profile
  (import compiler_startup_profile as startup_profile))
(import compiler_optimize)
(import stdlib.text_buf)
(import sym_i64_env)

(defenum ResultCompilerDriver
  (Ok String)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defenum ResultCompilerDriverBuffer
  (Ok text_buf.TextBuf)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defenum ResultCompilerDriverPic
  (Ok compiler_backend.CompilerBackendPicOutput)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defenum ResultCompilerDriverObject
  (Ok cobj.CompilerObjectImage)
  (Unavailable String)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defenum ResultCompilerDriverPackageRuntime
  (Object cobj.CompilerObjectImage String)
  (Assembly String String)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defenum ResultCompilerDriverLowered
  (Ok
    compiler_ir_types.CompilerIrProgram
    compiler_ir_types.CompilerSourceSpans
    compiler_ast_types.AstNodePoolContext
    profile_state.CompilerProfileState
    compiler_backend.CompilerBackendState
    compiler_typecheck_core.TcJobState)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

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
  (expr-pool (__tl_dyn-array compiler_ast_types.AstExprNodePoolState))
  (type-pool (__tl_dyn-array compiler_ast_types.AstTypeNodePoolState))
  (intern-state (__tl_dyn-array ci.InternCompatState))
  (parser-state compiler_parse_core.CompilerParseState)
  (builtin-ids (__tl_dyn-array cbi.CompilerBuiltinIdsState))
  (lower-state-address (__tl_dyn-array i64))
  (load-session compiler_load.CompilerLoadSessionState)
  (typecheck-state compiler_typecheck_core.TcJobState)
  (backend-state compiler_backend.CompilerBackendState)
  (typecheck-prefix-cache compiler_typecheck_core.TcPrefixSnapshotCacheState)
  (pool-arena (__tl_dyn-array i64))
  (surface-arena i64)
  (profile-state profile_state.CompilerProfileState))

;; The three state fragments intentionally allocated in the driver's retained
;; surface arena. Keeping the bundle local to construction lets one `in-arena`
;; extent preserve their allocation order while restoring the caller before
;; the outer state installs any of them.
(defenum CompilerDriverSurfaceState
  (State
    compiler_typecheck_core.TcJobState
    i64
    compiler_backend.CompilerBackendState))

(define (compiler-driver-state-new-from-pools-and-arena
  [expr-pool : compiler_ast_types.AstExprNodePoolState]
  [type-pool : compiler_ast_types.AstTypeNodePoolState]
  [pool-arena : i64]) : CompilerDriverState
  (let
    [expr-cell : (__tl_dyn-array compiler_ast_types.AstExprNodePoolState)
      (__tl_make-array compiler_ast_types.AstExprNodePoolState 1)]
    [type-cell : (__tl_dyn-array compiler_ast_types.AstTypeNodePoolState)
      (__tl_make-array compiler_ast_types.AstTypeNodePoolState 1)]
    [intern-cell : (__tl_dyn-array ci.InternCompatState)
      (__tl_make-array ci.InternCompatState 1)]
    [builtin-cell : (__tl_dyn-array cbi.CompilerBuiltinIdsState)
      (__tl_make-array cbi.CompilerBuiltinIdsState 1)]
    [lower-cell : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [pool-arena-cell : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    ;; Intern capability identity is shared by parser, lowering, and backend.
    ;; Create it before switching arenas; the backend's own state data is
    ;; allocated below while the driver's surface arena is current.
    [intern-state : ci.InternCompatState
      (cfg
        (any compile-profile test)
        (ci.intern-compat-state-new-with-profile-metrics-address
          (profile_state.compiler-profile-state-metrics-address profile-state))
        (ci.intern-compat-state-new))]
    [surface-arena : i64 (arena.tl_arena_make)]
    ;; The typecheck caches share the driver's lifetime with hydrated surface
    ;; data. Allocate them in that already-reserved arena instead of extending
    ;; the process entry arena by a full segment near its capacity boundary.
    [surface-state : CompilerDriverSurfaceState
      (in-arena
        (arena.Arena surface-arena)
        (CompilerDriverSurfaceState.State
          (cfg
            (any compile-profile test)
            (compiler_typecheck_core.tc-job-state-new-with-profile-metrics-address
              (profile_state.compiler-profile-state-typecheck-metrics-address
                (owned_view.compiler-owned-shared-view profile-state)))
            (compiler_typecheck_core.tc-job-state-new))
          (__tl-project-field
            (compiler_lower.compiler-lower-state-new-with-intern-state-and-profile-state
              (owned_view.compiler-owned-shared-view intern-state)
              (owned_view.compiler-owned-shared-view profile-state))
            address)
          (compiler_backend.compiler-backend-state-new-with-metrics
            (owned_view.compiler-owned-shared-view intern-state)
            (profile_state.compiler-profile-state-metrics
              (owned_view.compiler-owned-shared-view profile-state)))))]
    (match surface-state
      [(CompilerDriverSurfaceState.State
          typecheck-state
          lower-state-address
          backend-state)
        (begin
          (set! (array-ref expr-cell 0) expr-pool)
          (set! (array-ref type-cell 0) type-pool)
          (set! (array-ref intern-cell 0) intern-state)
          (set! (array-ref builtin-cell 0) (cbi.state-new))
          (set! (array-ref lower-cell 0) lower-state-address)
          (set! (array-ref pool-arena-cell 0) pool-arena)
          (CompilerDriverState
            expr-cell
            type-cell
            (owned_view.compiler-owned-shared-view intern-cell)
            (compiler_parse_core.compiler-parse-state-new-with-intern-state
              (owned_view.compiler-owned-array-element-shared-view
                intern-cell
                0))
            builtin-cell
            lower-cell
            (compiler_load.compiler-load-session-state-new)
            typecheck-state
            backend-state
            (compiler_typecheck_core.tc-prefix-snapshot-cache-state-new)
            pool-arena-cell
            surface-arena
            profile-state))])))

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
(define compiler-driver-detached-compat-pools : (__tl_dyn-array
    compiler_ast_types.AstNodePoolContext)
  ;; This sentinel is never read or written. Snapshot the process-global
  ;; compatibility fallback instead of allocating a duplicate 64K expression
  ;; segment into the process-lifetime default arena.
  (__tl_make-array (compiler_ast_types.ast-node-pool-context-capture-active)))

;; The detached compatibility context shares process-lifetime arena pools. A
;; shallow view is safe only at this internal compatibility boundary.
(define (compiler-driver-detached-compat-pools-shared-view) : compiler_ast_types.AstNodePoolContext
  (unsafe
    (ptr-read
      (ptr-cast
        (__tl_array-data compiler-driver-detached-compat-pools)
        : (Ptr compiler_ast_types.AstNodePoolContext)))))

(define (compiler-driver-state-detach-active-pools-if-owned!
  [pools : compiler_ast_types.AstNodePoolContext]) : unit
  (if (=
    (compiler_ast_types.ast-node-pool-owner-arena-handle)
    (compiler_ast_types.ast-node-pool-context-owner-arena pools))
    (compiler_ast_types.ast-node-pool-context-install!
      (compiler-driver-detached-compat-pools-shared-view))
    unit))

(define (compiler-driver-state-new-for-compile) : CompilerDriverState
  (let
    [pool-arena : i64 (compiler_ast_types.ast-node-pool-arena-make)]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-new-with-capacities-in-arena
        compiler-driver-compile-load-expr-pool-initial-capacity
        compiler-driver-compile-type-pool-initial-capacity
        pool-arena)]
    [state : CompilerDriverState
      (compiler-driver-state-new-from-pools-and-arena
        (owned_view.compiler-owned-array-element-shared-view pools.expr-pool 0)
        (owned_view.compiler-owned-array-element-shared-view pools.type-pool 0)
        (compiler_ast_types.ast-node-pool-context-base-arena pools))]
    (begin
      (cbi.state-capture-from-globals! (&mut (array-ref state.builtin-ids 0)))
      (compiler_lower.compiler-lower-arena-state-capture-from-globals!
        (compiler_lower.compiler-lower-state-arenas
          (compiler_lower.compiler-lower-state-from-address
            (owned_view.compiler-owned-array-element-shared-view
              state.lower-state-address
              0))))
      state)))

(define (compiler-driver-state-session-cache-enabled?
  [state : CompilerDriverState]) : bool
  (compiler_load.compiler-load-session-state-cache-enabled? state.load-session))

(define (compiler-driver-state-profile [state : CompilerDriverState]) : profile_state.CompilerProfileState
  state.profile-state)

(define (compiler-driver-state-backend [state : CompilerDriverState]) : compiler_backend.CompilerBackendState
  state.backend-state)

(define (compiler-driver-state-typecheck-prefix-cache
  [state : CompilerDriverState]) : compiler_typecheck_core.TcPrefixSnapshotCacheState
  state.typecheck-prefix-cache)

(define (compiler-driver-state-typecheck [state : CompilerDriverState]) : compiler_typecheck_core.TcJobState
  state.typecheck-state)

(define (compiler-driver-state-reset-typecheck! [state : CompilerDriverState]) : unit
  (compiler_typecheck_core.tc-job-state-reset-file-state!
    (compiler-driver-state-typecheck state)))

;; An intern reset publishes a new generation before the loader can record the
;; next entry's lazy import aliases. Bind that empty-generation snapshot now;
;; the post-load bind refreshes its source-count boundary without changing the
;; generation. Otherwise loader-produced aliases inherit the previous entry's
;; provenance and are discarded at the post-load bind.
(define (compiler-driver-state-bind-owned-source-names!
  [state : CompilerDriverState]) : unit
  (compiler_typecheck_core.tc-macro-state-bind-source-names!
    (compiler_typecheck_core.tc-job-state-macro-state
      (compiler-driver-state-typecheck
        (owned_view.compiler-owned-shared-view state)))
    (compiler-driver-state-source-name-session-in-current state)))

(define (compiler-driver-state-prefix-cache-enable!
  [state : CompilerDriverState]) : unit
  (compiler_typecheck_core.tc-prefix-snapshot-cache-enable-for-state!
    state.typecheck-prefix-cache))

(define (compiler-driver-state-prefix-cache-disable!
  [state : CompilerDriverState]) : unit
  (compiler_typecheck_core.tc-prefix-snapshot-cache-disable-for-state!
    state.typecheck-prefix-cache))

(define (compiler-driver-state-prefix-cache-clear!
  [state : CompilerDriverState]) : unit
  (compiler_typecheck_core.tc-prefix-snapshot-cache-clear-for-state!
    state.typecheck-prefix-cache))

(define (compiler-driver-state-prefix-cache-print-stats
  [state : CompilerDriverState]
  [label : String]) : unit
  (compiler_typecheck_core.tc-prefix-snapshot-cache-print-stats-for-state
    state.typecheck-prefix-cache
    label))

(define (compiler-driver-state-session-program-cache-disable
  [state : CompilerDriverState]) : CompilerDriverState
  (begin
    (compiler_load.compiler-load-session-state-program-cache-disable!
      state.load-session)
    state))

(define (compiler-driver-state-apply-session-flags!
  [state : CompilerDriverState]) : unit
  (compiler_load.compiler-load-session-state-use-with-intern-state!
    state.load-session
    (owned_view.compiler-owned-array-element-shared-view state.intern-state 0)))

;; Legacy/test adapter for compiler phases that still use the active pool
;; globals. State-owned reset/adopt operations must not call this helper.
(define (compiler-driver-state-install-pools! [state : CompilerDriverState]) : unit
  (begin
    (set!
      (array-ref compiler-driver-active-state-pool-arena 0)
      (compiler-driver-state-owned-pool-arena
        (owned_view.compiler-owned-shared-view state)))
    (set!
      (array-ref compiler-driver-active-state-surface-arena 0)
      (compiler-driver-state-surface-arena
        (owned_view.compiler-owned-shared-view state)))
    (compiler_ast_types.ast-node-pool-context-install!
      (compiler-driver-state-pool-context state))))

;; The most recently installed driver state's own pool arena, or 0 when no
;; state is installed. The allocation snapshot reports this as `state-pool-arena`
;; because the compatibility pool-global handle deliberately points at the 1x1
;; detached compat pools (entry arena) once the source arena is detached, so
;; `compiler-driver-node-pool-base-arena` cannot name the checked-program arena.
(define compiler-driver-active-state-pool-arena : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define compiler-driver-active-state-surface-arena : (__tl_dyn-array i64)
  (__tl_make-array i64 1))

;; Legacy/test adapter for the remaining load/typecheck/lower call graph.
;; State-owned table and persistent-arena maintenance uses the explicit
;; `InternCompatState` APIs and must happen before this boundary.
(define (compiler-driver-state-install-interns! [state : CompilerDriverState]) : unit
  (ci.intern-compat-state-install!
    (owned_view.compiler-owned-array-element-shared-view state.intern-state 0)))

(define (compiler-driver-node-pool-base-arena) : i64
  (compiler_ast_types.ast-node-pool-base-arena-handle))

;; Emit owner candidates plus the active arena at stable compiler phase
;; boundaries. `arena_root` lets consumers de-duplicate an active arena that is
;; also one of the named owners.
(define (compiler-driver-allocation-profile-snapshot-for-job!
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [phase : String]) : unit
  (if (= (allocation_profile.compiler-allocation-profile-control! 0 "" "" 0) 0)
    unit
    (begin
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "active"
        (arena.tl_arena_current))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "compiler-entry"
        (allocation_profile.compiler-allocation-profile-entry-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "source-pools"
        (compiler-driver-node-pool-base-arena))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "state-pool-arena"
        (array-ref compiler-driver-active-state-pool-arena 0))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "state-surface-arena"
        (array-ref compiler-driver-active-state-surface-arena 0))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "expr-pool-storage"
        (compiler_ast_types.ast-node-pool-expr-storage-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "type-pool-storage"
        (compiler_ast_types.ast-node-pool-type-storage-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "intern-persistent"
        (ci.intern-persistent-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "ir-labels"
        (compiler_ir_types.compiler-ir-label-arena-handle-value))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "ir-symbols"
        (compiler_ir_types.compiler-ir-symbol-arena-handle-value))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "load-provenance"
        (compiler_load.compiler-load-provenance-arena-handle-value))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "lexer-token-buffer"
        (compiler_load.compiler-load-lex-token-buffer-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "reader-node-pool"
        (compiler_load.compiler-load-reader-node-pool-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "reader-sexpr-pool"
        (compiler_load.compiler-load-reader-sexpr-pool-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "typecheck-aggregate-layout-cache"
        (compiler_typecheck_core.tc-agg-layout-cache-storage-arena-handle-value-for-job
          typecheck-state))
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "lower-scratch"
        compiler_lower.lower-scratch-arena)
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "lower-ir"
        compiler_lower.lower-ir-arena)
      unit)))

(define (compiler-driver-allocation-profile-snapshot! [phase : String]) : unit
  (compiler-driver-allocation-profile-snapshot-for-job!
    (compiler_typecheck_core.TcJobState 0)
    phase))

(define (compiler-driver-allocation-profile-pool-storage-snapshot!
  [phase : String]
  [pools : compiler_ast_types.AstNodePoolContext]) : unit
  (if (= (allocation_profile.compiler-allocation-profile-control! 0 "" "" 0) 0)
    unit
    (begin
      (allocation_profile.compiler-allocation-profile-control!
        2
        (owned_view.compiler-owned-shared-view phase)
        "expr-pool-storage"
        (compiler_ast_types.ast-node-pool-context-expr-storage-arena pools))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "type-pool-storage"
        (compiler_ast_types.ast-node-pool-context-type-storage-arena pools))
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
        (compiler_typecheck_core.tc-prefix-snapshot-cache-arena-value-for-state
          state.typecheck-prefix-cache))
      unit)))

(define (compiler-driver-allocation-profile-backend-output-snapshot!
  [backend-state : compiler_backend.CompilerBackendState]) : unit
  (if (= (allocation_profile.compiler-allocation-profile-control! 0 "" "" 0) 0)
    unit
    (begin
      (allocation_profile.compiler-allocation-profile-control!
        2
        "backend"
        "backend-output-home"
        (compiler_backend.compiler-backend-assembly-stream-home-arena-handle-value
          (compiler_backend.compiler-backend-state-stream-state backend-state)))
      unit)))

(define (compiler-driver-state-pool-context [state : CompilerDriverState]) : compiler_ast_types.AstNodePoolContext
  (compiler_ast_types.ast-node-pool-context-from-cells
    state.expr-pool
    state.type-pool
    (array-ref state.pool-arena 0)))

(define (compiler-driver-state-owned-pool-arena [state : CompilerDriverState]) : i64
  (array-ref state.pool-arena 0))

(define (compiler-driver-state-surface-arena [state : CompilerDriverState]) : i64
  state.surface-arena)

(define (compiler-driver-state-has-owned-pool-arena?
  [state : CompilerDriverState]) : bool
  (not (= (compiler-driver-state-owned-pool-arena state) 0)))

(define (compiler-driver-state-adopt-pools!
  [state : CompilerDriverState]
  [pools : compiler_ast_types.AstNodePoolContext]) : unit
  (begin
    (set!
      (array-ref state.pool-arena 0)
      (compiler_ast_types.ast-node-pool-context-base-arena pools))
    (set!
      (array-ref compiler-driver-active-state-pool-arena 0)
      (compiler_ast_types.ast-node-pool-context-base-arena pools))
    (set! (array-ref state.expr-pool 0) (array-ref pools.expr-pool 0))
    (set! (array-ref state.type-pool 0) (array-ref pools.type-pool 0))))

(define (compiler-driver-state-can-release-checked-lower-source-pools?
  [state : CompilerDriverState]) : bool
  (and
    (compiler-driver-state-has-owned-pool-arena?
      (owned_view.compiler-owned-shared-view state))
    (not (compiler-driver-state-session-cache-enabled? state))))

(define (compiler-driver-state-new-checked-lower-pools) : compiler_ast_types.AstNodePoolContext
  (let
    [pool-arena : i64 (compiler_ast_types.ast-node-pool-arena-make)]
    ;; Keep the context's wrapper cells with its backing arrays. Early source
    ;; retirement can otherwise unmap wrapper cells allocated in the frontend
    ;; arena before an error path gets a chance to release this pool.
    (in-arena
      (arena.Arena pool-arena)
      (compiler_ast_types.ast-node-pool-context-new-with-capacities-in-arena
        compiler-driver-checked-lower-expr-pool-initial-capacity
        compiler-driver-compile-type-pool-initial-capacity
        pool-arena))))

(define (compiler-driver-state-destroy-uncommitted-pools!
  [pools : compiler_ast_types.AstNodePoolContext]) : unit
  (begin
    ;; Checked lowering installs its destination pools into the compatibility
    ;; globals before it can fail. On an uncommitted error, detach that active
    ;; view before destroying the pool; otherwise batch cleanup can capture the
    ;; now-unmapped context cells after the diagnostic has been emitted.
    ;; Refs #5448.
    (compiler-driver-state-detach-active-pools-if-owned!
      (owned_view.compiler-owned-shared-view pools))
    (compiler_ast_types.ast-node-pool-context-destroy-storage!
      (owned_view.compiler-owned-shared-view pools))
    (unsafe
      (arena.tl_arena_destroy
        (compiler_ast_types.ast-node-pool-context-base-arena pools)))))

(define (compiler-driver-state-retain-lowered-types!
  [state : CompilerDriverState]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [pools : compiler_ast_types.AstNodePoolContext]) : ResultCompilerDriverLowered
  (let
    [old-arena : i64
      (compiler_ast_types.ast-node-pool-context-base-arena pools)]
    [old-expr-storage-arena : i64
      (compiler_ast_types.ast-node-pool-context-expr-storage-arena pools)]
    [old-type-storage-arena : i64
      (compiler_ast_types.ast-node-pool-context-type-storage-arena pools)]
    [retained : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-clone-types-only
        (owned_view.compiler-owned-shared-view pools))]
    (begin
      (compiler-driver-state-adopt-pools!
        (owned_view.compiler-owned-shared-view state)
        (owned_view.compiler-owned-shared-view retained))
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
          (arena.tl_arena_set
            (compiler_ast_types.ast-node-pool-context-base-arena retained)))
        unit)
      (compiler_ast_types.ast-node-pool-reader-use!
        (owned_view.compiler-owned-shared-view retained))
      (compiler-driver-allocation-profile-pool-storage-snapshot!
        "retained-reader"
        (owned_view.compiler-owned-shared-view retained))
      (cfg
        compile-profile
        (compiler_lower.compiler-lower-profile-pools
          "retained_reader"
          (owned_view.compiler-owned-shared-view retained))
        unit)
      (set! compiler-driver-pending-retired-source-arena old-arena)
      (set!
        compiler-driver-pending-retired-source-expr-storage-arena
        old-expr-storage-arena)
      (set!
        compiler-driver-pending-retired-source-type-storage-arena
        old-type-storage-arena)
      (compiler-driver-lowered-from-pools-and-profile-state-and-backend-state
        program
        spans
        retained
        (compiler-driver-state-profile
          (owned_view.compiler-owned-shared-view state))
        (compiler-driver-state-backend
          (owned_view.compiler-owned-shared-view state))
        (compiler-driver-state-typecheck state)))))

(define (compiler-driver-state-clear-pool-backed-caches-for-state!
  [state : CompilerDriverState]) : unit
  (begin
    (compiler_load.compiler-load-session-state-floors-set!
      (owned_view.compiler-owned-shared-view state.load-session)
      0
      0
      0)
    (compiler_load.compiler-load-session-state-program-cache-clear!
      (owned_view.compiler-owned-shared-view state.load-session))
    (compiler_load.compiler-load-session-state-runtime-prelude-cache-clear!
      state.load-session)
    (compiler_typecheck_core.tc-prefix-snapshot-cache-invalidate-for-state!
      state.typecheck-prefix-cache)))

;; Serial compatibility adapter for the post-lowering arena retirement path.
(define (compiler-driver-state-clear-pool-backed-caches!) : unit
  (begin
    (compiler_load.compiler-load-session-floors-set! 0 0 0)
    (compiler_load.compiler-load-program-cache-clear!)
    (compiler_load.compiler-load-runtime-prelude-cache-clear!)
    (compiler_typecheck_core.tc-prefix-snapshot-cache-clear!)))

(define (compiler-driver-state-replace-owned-pool-arena-if-uncached!
  [state : CompilerDriverState]
  [expr-capacity : i64]
  [type-capacity : i64]) : unit
  (if (or
    (not
      (compiler-driver-state-has-owned-pool-arena?
        (owned_view.compiler-owned-shared-view state)))
    (compiler-driver-state-session-cache-enabled?
      (owned_view.compiler-owned-shared-view state)))
    unit
    (let
      ;; The pool payload arena may grow past its root during a compile.
      ;; Destroy the installed head we just retired; the runtime root also tracks
      ;; that newest live segment so either head or root handle reclaims the chain.
      [old-newest : i64
        (compiler_ast_types.ast-node-pool-context-base-arena
          (compiler-driver-state-pool-context
            (owned_view.compiler-owned-shared-view state)))]
      [new-arena : i64 (compiler_ast_types.ast-node-pool-arena-make)]
      (begin
        (compiler-driver-state-clear-pool-backed-caches-for-state!
          (owned_view.compiler-owned-shared-view state))
        ;; Do not materialize the replacement backing arrays while the retired
        ;; pool chain is still live. If that chain is also the active arena,
        ;; move allocation to the already-created replacement root first.
        (if (= (arena.tl_arena_current) old-newest)
          (unsafe
            (arena.tl_arena_set new-arena))
          unit)
        (compiler-driver-state-detach-active-pools-if-owned!
          (compiler-driver-state-pool-context
            (owned_view.compiler-owned-shared-view state)))
        (compiler_ast_types.ast-node-pool-context-destroy-storage!
          (compiler-driver-state-pool-context
            (owned_view.compiler-owned-shared-view state)))
        (if (= (arena.tl_arena_current) old-newest)
          (unsafe
            (arena.tl_arena_set new-arena))
          unit)
        (unsafe
          (arena.tl_arena_destroy old-newest))
        (let
          [pools : compiler_ast_types.AstNodePoolContext
            (compiler_ast_types.ast-node-pool-context-new-with-capacities-in-arena
              expr-capacity
              type-capacity
              new-arena)]
          (begin
            (set!
              (array-ref state.pool-arena 0)
              (compiler_ast_types.ast-node-pool-context-base-arena pools))
            ;; Keep the snapshot handle naming a live arena: the old pool
            ;; chain was destroyed above, and the next entry's load-phase
            ;; state-pool-arena row walks this global before any reinstall.
            (set!
              (array-ref compiler-driver-active-state-pool-arena 0)
              (compiler_ast_types.ast-node-pool-context-base-arena pools))
            (set! (array-ref state.expr-pool 0) (array-ref pools.expr-pool 0))
            (set! (array-ref state.type-pool 0) (array-ref pools.type-pool 0))))))))

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
    (not
      (compiler-driver-state-has-owned-pool-arena?
        (owned_view.compiler-owned-shared-view state)))
    (compiler-driver-state-session-cache-enabled?
      (owned_view.compiler-owned-shared-view state)))
    unit
    (ci.intern-compat-state-persistent-arena-reset!
      (&mut (array-ref state.intern-state 0)))))

;; The state's owned builtin/CTFE id snapshot.
(define (compiler-driver-state-owned-builtins [state : CompilerDriverState]) : cbi.CompilerBuiltinIdsState
  (array-ref state.builtin-ids 0))

(define (compiler-driver-state-owned-builtins-mut [state : CompilerDriverState]) : (&mut
    state
    cbi.CompilerBuiltinIdsState)
  (&mut (array-ref state.builtin-ids 0)))

;; The state's owned lower traversal/index/cache carrier.
(define (compiler-driver-state-owned-lower-state [state : CompilerDriverState]) : compiler_lower.CompilerLowerState
  (compiler_lower.compiler-lower-state-from-address
    (array-ref state.lower-state-address 0)))

;; The lower job owner composes the existing scratch/IR arena carrier.
(define (compiler-driver-state-owned-lower-arenas [state : CompilerDriverState]) : compiler_lower.CompilerLowerArenaState
  (compiler_lower.compiler-lower-state-arenas
    (compiler-driver-state-owned-lower-state state)))

(define (compiler-driver-state-install-lower-arenas!
  [state : CompilerDriverState]) : unit
  (compiler_lower.compiler-lower-arena-state-install!
    (compiler-driver-state-owned-lower-arenas state)))

;; Legacy/test capture paired with `compiler-driver-state-install-interns!`.
(define (compiler-driver-state-capture-active-interns!
  [state : CompilerDriverState]) : unit
  (ci.intern-compat-state-capture-from-globals!
    (&mut (array-ref state.intern-state 0))))

(define (compiler-driver-state-intern-generation [state : CompilerDriverState]) : i64
  (ci.intern-compat-state-generation (array-ref state.intern-state 0)))

(define (compiler-driver-state-owned-interns [state : CompilerDriverState]) : ci.InternCompatState
  (array-ref state.intern-state 0))

(define (compiler-driver-state-owned-interns-mut [state : CompilerDriverState]) : (&mut
    state
    ci.InternCompatState)
  (&mut (array-ref state.intern-state 0)))

;; Allocate an immutable source-name snapshot in an explicit owner. Production
;; batch entries keep their snapshot in the rotating entry scratch arena; only
;; callers that explicitly request a retained driver capability use the
;; process-lived surface arena below.
(define (compiler-driver-state-source-name-session-in-arena
  [state : CompilerDriverState]
  [owner : i64]) : ci.InternSourceNameSessionHandle
  (in-arena
    (arena.Arena owner)
    (let
      [intern-state : ci.InternCompatState
        (compiler-driver-state-owned-interns state)]
      (ci.intern-source-name-session-handle-from-state (& intern-state)))))

(define (compiler-driver-state-source-name-session-in-current
  [state : CompilerDriverState]) : ci.InternSourceNameSessionHandle
  (compiler-driver-state-source-name-session-in-arena
    state
    (arena.tl_arena_current)))

;; Opt1/2 parsing runs in a disposable frontend arena, but the capability must
;; survive through lower reachability and backend emission. Route that one
;; snapshot into the saved entry arena instead of accumulating it in the
;; driver's process-lived surface arena across batch entries.
(define (compiler-driver-state-entry-source-name-session
  [state : CompilerDriverState]) : ci.InternSourceNameSessionHandle
  (compiler-driver-state-source-name-session-in-arena
    state
    (if (= compiler-driver-pending-frontend-return-arena 0)
      (arena.tl_arena_current)
      compiler-driver-pending-frontend-return-arena)))

(define (compiler-driver-state-entry-structural-session
  [state : CompilerDriverState]) : cis.InternStructuralSessionHandle
  (cis.intern-structural-session-handle-from-source-names
    (compiler-driver-state-entry-source-name-session state)))

;; Retained adapter for callers whose capability must survive an arbitrary
;; caller arena. Per-entry compiler paths use the rotating adapter above.
(define (compiler-driver-state-source-name-session
  [state : CompilerDriverState]) : ci.InternSourceNameSessionHandle
  (compiler-driver-state-source-name-session-in-arena
    (owned_view.compiler-owned-shared-view state)
    (compiler-driver-state-surface-arena state)))

(define (compiler-driver-state-structural-session [state : CompilerDriverState]) : cis.InternStructuralSessionHandle
  (cis.intern-structural-session-handle-from-source-names
    (compiler-driver-state-source-name-session state)))

(cfg
  test
  (test
    compiler-driver-source-name-session-retained-owner
    (let
      [state : CompilerDriverState (compiler-driver-state-new-for-compile)]
      [return-arena : i64 (arena.tl_arena_current)]
      [transient-arena : i64 (arena.tl_arena_make)]
      [source-names : ci.InternSourceNameSessionHandle
        (begin
          (unsafe
            (arena.tl_arena_set transient-arena))
          (let
            [session : ci.InternSourceNameSessionHandle
              (compiler-driver-state-source-name-session
                (owned_view.compiler-owned-shared-view state))]
            (begin
              (unsafe
                (arena.tl_arena_set return-arena))
              session)))]
      [intern-state : ci.InternCompatState
        (compiler-driver-state-owned-interns
          (owned_view.compiler-owned-shared-view state))]
      (begin
        (unsafe
          (arena.tl_arena_destroy transient-arena))
        (test.assert-i64-eq
          (ci.intern-source-name-session-handle-table-id source-names)
          (ci.intern-compat-state-table-id (& intern-state))
          "source-name capability survives retirement of the caller arena")
        (test.assert-i64-eq
          (cast
            (ci.intern-compat-state-profile-metrics-address-ref
              (& intern-state))
            : i64)
          (cast
            (profile_state.compiler-profile-state-metrics-address
              (compiler-driver-state-profile state))
            : i64)
          "intern owner shares the driver profile metric array")))))

(define (compiler-driver-state-capture-active-builtins!
  [state : CompilerDriverState]) : unit
  (cbi.state-capture-from-globals! (&mut (array-ref state.builtin-ids 0))))

;; State-owned builtin reset: clears the state's own metadata and, only when
;; this state's table is the installed one, invalidates the compatibility
;; globals (CTFE builtin ids share the table and invalidate with it). No
;; install bridge: the next parse of this state re-derives the table.
(define (compiler-driver-state-reset-builtins! [state : CompilerDriverState]) : unit
  (cbi.state-reset! (compiler-driver-state-owned-builtins-mut state)))

;; State-owned lower-arena release: destroys the arenas named by the state's
;; own cells, zeroing the compatibility selectors only while they still name
;; this state's handles. No install/capture bridge.
(define (compiler-driver-state-release-lower-arenas!
  [state : CompilerDriverState]) : unit
  (compiler_lower.compiler-lower-arena-state-release!
    (compiler-driver-state-owned-lower-arenas state)))

(define (compiler-driver-state-reset-lower! [state : CompilerDriverState]) : unit
  (compiler_lower.compiler-lower-state-reset!
    (compiler-driver-state-owned-lower-state state)))

(define (compiler-driver-state-capture-active-lower-arenas!
  [state : CompilerDriverState]) : unit
  (compiler_lower.compiler-lower-arena-state-capture-from-globals!
    (compiler-driver-state-owned-lower-arenas state)))

;; Session-floor snapshot after a batch entry: refresh the state's builtin and
;; lower-arena cells from the compatibility globals the phases just used, so a
;; later state-owned reset/release sees the current (possibly grown) handles.
(define (compiler-driver-state-capture-active-transients!
  [state : CompilerDriverState]) : unit
  (begin
    (compiler-driver-state-capture-active-builtins!
      (owned_view.compiler-owned-shared-view state))
    (compiler-driver-state-capture-active-lower-arenas! state)))

(define (compiler-driver-state-capture-session-floors!
  [state : CompilerDriverState]) : unit
  (begin
    ;; Load/typecheck/lower mutate the state-owned context cells directly; do
    ;; not overwrite them from whichever compatibility pool happens to be
    ;; installed when a batch entry finishes, and do not install the loader's
    ;; serial/test selector as a compile-job handoff.
    (compiler-driver-state-capture-active-interns!
      (owned_view.compiler-owned-shared-view state))
    (compiler-driver-state-capture-active-transients! state)))

(define (compiler-driver-lowered-from-active-pools-and-profile-state-and-backend-state
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : compiler_backend.CompilerBackendState]) : ResultCompilerDriverLowered
  (ResultCompilerDriverLowered.Ok
    program
    spans
    (compiler_ast_types.ast-node-pool-context-capture-active)
    profile-state
    backend-state
    (compiler_typecheck_core.tc-serial-job-state)))

(define (compiler-driver-lowered-from-active-pools-and-profile-state
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverLowered
  (let
    [backend-state : compiler_backend.CompilerBackendState
      (compiler_backend.compiler-backend-state-new-with-metrics
        (ci.intern-compat-state-capture-active)
        (profile_state.compiler-profile-state-metrics
          (owned_view.compiler-owned-shared-view profile-state)))]
    (compiler-driver-lowered-from-active-pools-and-profile-state-and-backend-state
      program
      spans
      profile-state
      backend-state)))

(define (compiler-driver-lowered-from-active-pools
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]) : ResultCompilerDriverLowered
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    [backend-state : compiler_backend.CompilerBackendState
      (compiler_backend.compiler-backend-state-new-with-metrics
        (ci.intern-compat-state-capture-active)
        (profile_state.compiler-profile-state-metrics
          (owned_view.compiler-owned-shared-view profile-state)))]
    (compiler-driver-lowered-from-active-pools-and-profile-state-and-backend-state
      program
      spans
      profile-state
      backend-state)))

(define (compiler-driver-lowered-from-pools-and-profile-state-and-backend-state
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [pools : compiler_ast_types.AstNodePoolContext]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : compiler_backend.CompilerBackendState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerDriverLowered
  (ResultCompilerDriverLowered.Ok
    program
    spans
    (compiler_ast_types.ast-node-pool-context-snapshot pools)
    profile-state
    backend-state
    typecheck-state))

(define (compiler-driver-runtime-prelude-cache-lookup-with-state
  [load-state : compiler_load.CompilerLoadSessionState]
  [key : compiler_load.CompilerLoadPreludeCacheKey]) : compiler_load.CompilerLoadPreludeCacheLookup
  (compiler_load.compiler-load-session-state-runtime-prelude-cache-lookup
    load-state
    key))

;; Helpers in this section that omit `load-state` are serial/test compatibility
;; adapters. Driver-owned compile paths call the explicit state-taking forms.
(define (compiler-driver-runtime-prelude-cache-lookup
  [key : compiler_load.CompilerLoadPreludeCacheKey]) : compiler_load.CompilerLoadPreludeCacheLookup
  (compiler-driver-runtime-prelude-cache-lookup-with-state
    (compiler_load.compiler-load-active-session-state-shared-view)
    key))

(define (compiler-driver-runtime-prelude-cache-store-with-state
  [load-state : compiler_load.CompilerLoadSessionState]
  [key : compiler_load.CompilerLoadPreludeCacheKey]
  [decls : compiler_ast_types.AstDeclList]
  [paths : compiler_ast_types.AstDeclPathList]
  [modules : compiler_ast_types.AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]) : unit
  (compiler_load.compiler-load-session-state-runtime-prelude-cache-store
    load-state
    key
    decls
    paths
    modules
    seen))

(define (compiler-driver-runtime-prelude-cache-store
  [key : compiler_load.CompilerLoadPreludeCacheKey]
  [decls : compiler_ast_types.AstDeclList]
  [paths : compiler_ast_types.AstDeclPathList]
  [modules : compiler_ast_types.AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]) : unit
  (compiler-driver-runtime-prelude-cache-store-with-state
    (compiler_load.compiler-load-active-session-state-shared-view)
    key
    decls
    paths
    modules
    seen))

(define (compiler-driver-runtime-prelude-cache-store-with-state-and-pools
  [load-state : compiler_load.CompilerLoadSessionState]
  [key : compiler_load.CompilerLoadPreludeCacheKey]
  [decls : compiler_ast_types.AstDeclList]
  [paths : compiler_ast_types.AstDeclPathList]
  [modules : compiler_ast_types.AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]) : unit
  (compiler_load.compiler-load-session-state-runtime-prelude-cache-store-with-pools
    load-state
    key
    decls
    paths
    modules
    seen
    pools))

(define (compiler-driver-ty-node-pool-exhausted-diagnostic
  [input-path : String]) : compiler_diagnostic.CompilerDiagnostic
  (compiler_diagnostic.compiler-diagnostic-at-start
    input-path
    (compiler_ast_types.ty-node-pool-exhausted-message)))

(define (compiler-driver-reset-file-state!) : unit
  (begin
    ;; Compatibility reset for serial standalone helpers. Driver-state callers
    ;; install their active state before this and capture it again afterward.
    (compiler_load.compiler-load-default-session-use!)
    (compiler_load.compiler-load-session-reset-pools!)
    (compiler_load.compiler-load-session-reset-interns!)
    (compiler_typecheck_core.compiler-typecheck-reset-intern-owned-state!)
    (cbi.compiler-builtin-reset!)
    (compiler_ctfe.ctfe-builtin-reset!)
    (compiler_typecheck_core.compiler-typecheck-reset-file-state!)
    (compiler_lower.lower-reset-file-state!)
    ;; Drop the previous entry's lowerer arenas. At opt level 0
    ;; the escaped IR stays alive until the next file reset.
    (compiler_lower.lower-arenas-release!)))

(define (compiler-driver-reset-analysis-state!) : unit
  (begin
    (cbi.compiler-builtin-reset!)
    (compiler_ctfe.ctfe-builtin-reset!)
    (compiler_typecheck_core.compiler-typecheck-reset-file-state!)
    (compiler_lower.lower-reset-file-state!)
    (compiler_lower.lower-arenas-release!)))

(define (compiler-driver-state-reset-file-state! [state : CompilerDriverState]) : unit
  (begin
    (compiler-driver-state-apply-session-flags!
      (owned_view.compiler-owned-shared-view state))
    (compiler-driver-state-reset-owned-pool-arena-if-uncached!
      (owned_view.compiler-owned-shared-view state))
    (compiler-driver-state-reset-owned-intern-arena-if-uncached!
      (owned_view.compiler-owned-shared-view state))
    (let
      [pools : compiler_ast_types.AstNodePoolContext
        (compiler-driver-state-pool-context
          (owned_view.compiler-owned-shared-view state))]
      (begin
        (compiler_load.compiler-load-session-state-reset-pools-with-pools!
          (owned_view.compiler-owned-shared-view state.load-session)
          pools)
        (compiler_load.compiler-load-session-state-reset-interns-with-state!
          (owned_view.compiler-owned-shared-view state.load-session)
          (&mut (array-ref state.intern-state 0)))
        (compiler-driver-state-bind-owned-source-names!
          (owned_view.compiler-owned-shared-view state))
        (compiler-driver-state-reset-typecheck!
          (owned_view.compiler-owned-shared-view state))
        (compiler_typecheck_core.compiler-typecheck-reset-intern-owned-state!)
        ;; Builtin/CTFE ids and lowerer arenas are state-owned: reset/release
        ;; through the state's own cells with no install/capture bridge. The
        ;; compatibility selectors are only touched while they name this
        ;; state's handles.
        (compiler-driver-state-reset-builtins!
          (owned_view.compiler-owned-shared-view state))
        (compiler_typecheck_core.compiler-typecheck-reset-file-state-for-job!
          (compiler-driver-state-typecheck
            (owned_view.compiler-owned-shared-view state)))
        (compiler_lower.lower-reset-file-state!)
        (compiler-driver-state-reset-lower!
          (owned_view.compiler-owned-shared-view state))
        ;; Drop the previous entry's lowerer arenas. At opt level 0
        ;; the escaped IR stays alive until the next file reset.
        (compiler-driver-state-release-lower-arenas!
          (owned_view.compiler-owned-shared-view state))))))

;; Post-emission batch cleanup. This runs while the caller-owned entry scratch
;; arena is still live, so it performs the same cache/intern/lower teardown as a
;; full file reset but leaves only a one-slot pool context behind. The next
;; entry's normal reset grows a fresh load pool after the old scratch chain is
;; gone instead of keeping a 4.39M-slot replacement live between entries.
(define (compiler-driver-state-release-file-state!
  [state : CompilerDriverState]) : unit
  (begin
    (compiler-driver-state-apply-session-flags!
      (owned_view.compiler-owned-shared-view state))
    (compiler-driver-state-release-owned-pool-arena-if-uncached!
      (owned_view.compiler-owned-shared-view state))
    (compiler-driver-state-reset-owned-intern-arena-if-uncached!
      (owned_view.compiler-owned-shared-view state))
    (let
      [pools : compiler_ast_types.AstNodePoolContext
        (compiler-driver-state-pool-context
          (owned_view.compiler-owned-shared-view state))]
      (begin
        (compiler_load.compiler-load-session-state-reset-pools-with-pools!
          (owned_view.compiler-owned-shared-view state.load-session)
          pools)
        (compiler_load.compiler-load-session-state-reset-interns-with-state!
          (owned_view.compiler-owned-shared-view state.load-session)
          (&mut (array-ref state.intern-state 0)))
        (compiler-driver-state-reset-typecheck!
          (owned_view.compiler-owned-shared-view state))
        (compiler_typecheck_core.compiler-typecheck-reset-intern-owned-state!)
        ;; State-owned builtin/CTFE reset and lowerer-arena release, exactly as
        ;; in `compiler-driver-state-reset-file-state!`.
        (compiler-driver-state-reset-builtins!
          (owned_view.compiler-owned-shared-view state))
        (compiler_typecheck_core.compiler-typecheck-reset-file-state-for-job!
          (compiler-driver-state-typecheck
            (owned_view.compiler-owned-shared-view state)))
        (compiler_lower.lower-reset-file-state!)
        (compiler-driver-state-reset-lower!
          (owned_view.compiler-owned-shared-view state))
        (compiler-driver-state-release-lower-arenas!
          (owned_view.compiler-owned-shared-view state))))))

(cfg
  compile-profile
  (define (compiler-driver-state-release-file-state-profiled!
    [state : CompilerDriverState]
    [ordinal : i64]) : unit
    (begin
      (compiler-driver-state-apply-session-flags!
        (owned_view.compiler-owned-shared-view state))
      ;; Post-emission cleanup deliberately installs only the compact one-slot
      ;; compatibility context. The next entry prepares full load capacity
      ;; after this entry's scratch chain is gone.
      (compiler-driver-state-release-owned-pool-arena-if-uncached!
        (owned_view.compiler-owned-shared-view state))
      (compiler-driver-batch-profile-mark!
        (compiler-driver-state-profile
          (owned_view.compiler-owned-shared-view state))
        ordinal
        "owned-pool-release")
      (compiler-driver-state-reset-owned-intern-arena-if-uncached!
        (owned_view.compiler-owned-shared-view state))
      (let
        [pools : compiler_ast_types.AstNodePoolContext
          (compiler-driver-state-pool-context
            (owned_view.compiler-owned-shared-view state))]
        (begin
          (compiler_load.compiler-load-session-state-reset-pools-with-pools!
            (owned_view.compiler-owned-shared-view state.load-session)
            (owned_view.compiler-owned-shared-view pools))
          (compiler_load.compiler-load-session-state-reset-interns-with-state!
            (owned_view.compiler-owned-shared-view state.load-session)
            (&mut (array-ref state.intern-state 0)))
          (compiler-driver-state-bind-owned-source-names!
            (owned_view.compiler-owned-shared-view state))
          (compiler-driver-state-reset-typecheck!
            (owned_view.compiler-owned-shared-view state))
          (compiler_typecheck_core.compiler-typecheck-reset-intern-owned-state!)
          (compiler-driver-state-reset-builtins!
            (owned_view.compiler-owned-shared-view state))
          (compiler_typecheck_core.compiler-typecheck-reset-file-state-for-job!
            (compiler-driver-state-typecheck
              (owned_view.compiler-owned-shared-view state)))
          (compiler-driver-batch-profile-mark!
            (compiler-driver-state-profile
              (owned_view.compiler-owned-shared-view state))
            ordinal
            "intern-session-cleanup")
          (compiler_lower.lower-reset-file-state!)
          (compiler-driver-state-reset-lower!
            (owned_view.compiler-owned-shared-view state))
          (compiler-driver-state-release-lower-arenas!
            (owned_view.compiler-owned-shared-view state))
          (compiler-driver-batch-profile-mark!
            (compiler-driver-state-profile
              (owned_view.compiler-owned-shared-view state))
            ordinal
            "lower-cleanup"))))))

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
  (any compile-profile test)
  (define compiler-driver-profile-prelude-source-pipeline-entries-metric : i64
    12))
(cfg
  (any compile-profile test)
  (define compiler-driver-profile-prelude-hydrations-metric : i64
    13))
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
  (any compile-profile test)
  (define (compiler-driver-profile-value
    [state : profile_state.CompilerProfileState]
    [metric : i64]) : i64
    (profile_state.compiler-profile-state-metric-value state metric)))

(defmacro (compiler-driver-profile-intern-metrics-address [state : Expr]) : Expr
  `(profile_state.compiler-profile-state-metrics-address ,state))

(cfg
  (any compile-profile test)
  (define (compiler-driver-profile-set!
    [state : profile_state.CompilerProfileState]
    [metric : i64]
    [value : i64]) : unit
    (profile_state.compiler-profile-state-metric-set! state metric value)))

(cfg
  (any compile-profile test)
  (define (compiler-driver-profile-add!
    [state : profile_state.CompilerProfileState]
    [metric : i64]
    [value : i64]) : unit
    (profile_state.compiler-profile-state-metric-add! state metric value)))

(define (compiler-driver-profile-reset-prelude!
  [_state : profile_state.CompilerProfileState]) : unit
  (cfg
    (any compile-profile test)
    (begin
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view _state)
        compiler-driver-profile-prelude-source-pipeline-entries-metric
        0)
      (compiler-driver-profile-set!
        _state
        compiler-driver-profile-prelude-hydrations-metric
        0))
    unit))

(define (compiler-driver-profile-note-prelude-source-pipeline!
  [_state : profile_state.CompilerProfileState]) : unit
  (cfg
    (any compile-profile test)
    (compiler-driver-profile-add!
      _state
      compiler-driver-profile-prelude-source-pipeline-entries-metric
      1)
    unit))

(define (compiler-driver-profile-note-prelude-hydration!
  [_state : profile_state.CompilerProfileState]) : unit
  (cfg
    (any compile-profile test)
    (compiler-driver-profile-add!
      _state
      compiler-driver-profile-prelude-hydrations-metric
      1)
    unit))

(cfg
  test
  (test
    compiler-driver-profile-prelude-job-isolation
    (let
      [left : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [right : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      (begin
        (compiler-driver-profile-reset-prelude!
          (profile_state.compiler-profile-state-shared-view left))
        (compiler-driver-profile-reset-prelude!
          (profile_state.compiler-profile-state-shared-view right))
        (compiler-driver-profile-note-prelude-source-pipeline!
          (profile_state.compiler-profile-state-shared-view left))
        (compiler-driver-profile-note-prelude-hydration!
          (profile_state.compiler-profile-state-shared-view right))
        (compiler-driver-profile-note-prelude-source-pipeline!
          (profile_state.compiler-profile-state-shared-view left))
        (compiler-driver-profile-note-prelude-hydration!
          (profile_state.compiler-profile-state-shared-view left))
        (compiler-driver-profile-reset-prelude!
          (profile_state.compiler-profile-state-shared-view right))
        (test.assert-i64-eq
          (compiler-driver-profile-value
            (profile_state.compiler-profile-state-shared-view left)
            compiler-driver-profile-prelude-source-pipeline-entries-metric)
          2
          "left job keeps interleaved source-pipeline count")
        (test.assert-i64-eq
          (compiler-driver-profile-value
            (profile_state.compiler-profile-state-shared-view left)
            compiler-driver-profile-prelude-hydrations-metric)
          1
          "right reset does not erase left hydration count")
        (test.assert-i64-eq
          (compiler-driver-profile-value
            (profile_state.compiler-profile-state-shared-view right)
            compiler-driver-profile-prelude-source-pipeline-entries-metric)
          0
          "right source-pipeline count resets independently")
        (test.assert-i64-eq
          (compiler-driver-profile-value
            right
            compiler-driver-profile-prelude-hydrations-metric)
          0
          "right hydration count resets independently")))))

(cfg
  test
  (test
    compiler-driver-profile-intern-job-isolation
    (let
      [left : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [right : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [left-address : u64
        (profile_state.compiler-profile-state-metrics-address left)]
      [right-address : u64
        (profile_state.compiler-profile-state-metrics-address right)]
      (begin
        (ci.intern-profile-reset! left-address)
        (ci.intern-profile-reset! right-address)
        (ci.intern-profile-note-intern left-address)
        (ci.intern-profile-note-slice left-address 7)
        (ci.intern-profile-note-lookup right-address)
        (ci.intern-profile-note-generated right-address)
        (ci.intern-profile-note-generated-role-create
          left-address
          (ci.intern-generated-symbol-role-lambda))
        (ci.intern-profile-reset! right-address)
        (test.assert-i64-eq
          (ci.intern-profile-value left-address ci.intern-profile-intern-metric)
          1
          "left job keeps interleaved intern count")
        (test.assert-i64-eq
          (ci.intern-profile-value
            left-address
            ci.intern-profile-slice-bytes-metric)
          7
          "right reset does not erase left slice bytes")
        (test.assert-i64-eq
          (ci.intern-profile-value
            left-address
            (+
              ci.intern-profile-generated-role-create-start-metric
              (ci.intern-generated-symbol-role-index
                (ci.intern-generated-symbol-role-lambda))))
          1
          "role counters use the same slot in the left owner")
        (test.assert-i64-eq
          (ci.intern-profile-value
            right-address
            ci.intern-profile-lookup-metric)
          0
          "right reset clears its lookup count")
        (test.assert-i64-eq
          (ci.intern-profile-value
            right-address
            ci.intern-profile-generated-metric)
          0
          "right reset clears its generated count")))))

(cfg
  test
  (test
    compiler-driver-profile-intern-storage-job-isolation
    (let
      [left : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [right : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [left-address : u64
        (profile_state.compiler-profile-state-metrics-address left)]
      [right-address : u64
        (profile_state.compiler-profile-state-metrics-address right)]
      [left-intern : ci.InternCompatState
        (ci.intern-compat-state-new-with-profile-metrics-address left-address)]
      [right-intern : ci.InternCompatState
        (ci.intern-compat-state-new-with-profile-metrics-address right-address)]
      (begin
        (ci.intern-profile-reset! left-address)
        (ci.intern-profile-reset! right-address)
        (ci.intern-compat-state-reset! (&mut left-intern))
        (ci.intern-compat-state-reset! (&mut right-intern))
        (let
          [left-source : i64
            (ci.intern-compat-state-intern
              (&mut left-intern)
              "left-profile-source")]
          [right-source : i64
            (ci.intern-compat-state-intern
              (&mut right-intern)
              "right-profile-source")]
          [left-canonical : i64
            (ci.intern-compat-state-generated-canonical-name
              (&mut left-intern)
              "left-profile-canonical")]
          [left-canonical-again : i64
            (ci.intern-compat-state-generated-canonical-name
              (&mut left-intern)
              "left-profile-canonical")]
          [right-generated : i64
            (ci.intern-compat-state-generated-name
              (&mut right-intern)
              "right-profile-generated")]
          (begin
            ;; A known larger observation proves max and total use the same
            ;; numeric slots in one owner without touching the other owner.
            (ci.intern-profile-note-source-map-probe! left-address 4)
            (test.assert-i64-eq
              left-source
              right-source
              "independent owners may assign the same source record id")
            (test.assert-i64-eq
              left-canonical
              right-generated
              "independent owners may assign the same generated record id")
            (test.assert-i64-eq
              left-canonical
              left-canonical-again
              "canonical generated insertion is counted once")
            (ci.intern-profile-reset! right-address)
            (ci.intern-compat-state-reset! (&mut right-intern))
            (test.assert-i64-eq
              (ci.intern-profile-value
                left-address
                ci.intern-profile-source-record-live-metric)
              1
              "right reset preserves left source record live count")
            (test.assert-i64-eq
              (ci.intern-profile-value
                left-address
                ci.intern-profile-generated-record-live-metric)
              1
              "right reset preserves left generated record live count")
            (test.assert-i64-eq
              (ci.intern-profile-value
                left-address
                ci.intern-profile-source-map-live-metric)
              1
              "left source map owns its occupancy")
            (test.assert-i64-eq
              (ci.intern-profile-value
                left-address
                ci.intern-profile-canonical-map-live-metric)
              1
              "left canonical map counts only the new record")
            (test.assert-i64-eq
              (ci.intern-profile-value
                left-address
                ci.intern-profile-source-map-probe-total-metric)
              5
              "source probe total accumulates per owner")
            (test.assert-i64-eq
              (ci.intern-profile-value
                left-address
                ci.intern-profile-source-map-probe-max-metric)
              4
              "source probe maximum is per owner")
            (test.assert-i64-eq
              (ci.intern-profile-value
                left-address
                ci.intern-profile-canonical-map-probe-total-metric)
              2
              "canonical insert and reuse each record one probe")
            (test.assert-i64-eq
              (ci.intern-profile-value
                right-address
                ci.intern-profile-source-record-live-metric)
              0
              "right reset clears only right live observations")
            (test.assert-i64-eq
              (ci.intern-profile-value
                right-address
                ci.intern-profile-source-record-capacity-metric)
              (ci.intern-capacity)
              "right reset restores fixed source record capacity")
            (test.assert-i64-eq
              (ci.intern-profile-value
                right-address
                ci.intern-profile-source-map-resize-metric)
              0
              "fixed source map reports zero resizes")
            (test.assert-true
              (>
                (ci.intern-profile-value
                  right-address
                  ci.intern-profile-record-reserved-bytes-metric)
                0)
              "right owner restores fixed record reserved bytes")))))))

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
    (str_cat.str-cat "|" (string.int->string value))))

(cfg
  compile-profile
  (define (compiler-driver-profile-line
    [phase : String]
    [elapsed-ms : i64]
    [alloc-delta : i64]
    [live-delta : i64]
    [peak-delta : i64]) : String
    (str_cat.str-cat
      "compile-profile|"
      phase
      (compiler-driver-profile-field elapsed-ms)
      (compiler-driver-profile-field alloc-delta)
      (compiler-driver-profile-field live-delta)
      (compiler-driver-profile-field peak-delta)
      "\n")))

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
    (str_cat.str-cat
      "\ncompile-batch-profile|"
      (string.int->string ordinal)
      "|"
      marker
      (compiler-driver-profile-field elapsed-ms)
      (compiler-driver-profile-field alloc-delta)
      (compiler-driver-profile-field live-delta)
      (compiler-driver-profile-field peak-delta)
      (compiler-driver-profile-field live-bytes)
      (compiler-driver-profile-field baseline-delta)
      "\n")))

(cfg
  compile-profile
  (define (compiler-driver-batch-profile-reset-baseline!
    [state : profile_state.CompilerProfileState]) : unit
    (begin
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-batch-profile-start-ms-metric
        (profile.now-ms))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-batch-profile-start-total-metric
        (profile.alloc-total))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
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
              (profile_state.compiler-profile-state-shared-view state)
              compiler-driver-batch-profile-first-live-metric
              live-bytes))
          unit)
        (compiler-driver-profile-set!
          (profile_state.compiler-profile-state-shared-view state)
          compiler-driver-batch-profile-best-peak-metric
          0)
        (compiler-driver-batch-profile-reset-baseline!
          (profile_state.compiler-profile-state-shared-view state))
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
                (profile_state.compiler-profile-state-shared-view state)
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
            (profile_state.compiler-profile-state-shared-view state)
            compiler-driver-batch-profile-best-peak-metric)
          (compiler-driver-profile-nonnegative
            (-
              (profile.alloc-peak)
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-batch-profile-start-live-metric))))]
      (begin
        (io.print-error
          (compiler-driver-batch-profile-line
            ordinal
            marker
            (-
              end-ms
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-batch-profile-start-ms-metric))
            (-
              end-total
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-batch-profile-start-total-metric))
            (-
              end-live
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-batch-profile-start-live-metric))
            peak-delta
            end-live
            (-
              end-live
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-batch-profile-first-live-metric))))
        (compiler-driver-profile-set!
          (profile_state.compiler-profile-state-shared-view state)
          compiler-driver-batch-profile-best-peak-metric
          0)
        (compiler-driver-batch-profile-reset-baseline!
          (profile_state.compiler-profile-state-shared-view state))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-phase
    [state : profile_state.CompilerProfileState]) : unit
    (begin
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-profile-phase-start-ms-metric
        (profile.now-ms))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-profile-phase-start-total-metric
        (profile.alloc-total))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-profile-phase-start-live-metric
        (profile.alloc-live))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-profile-phase-start-intern-metric
        (ci.intern-profile-intern-value
          (compiler-driver-profile-intern-metrics-address state)))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-profile-phase-start-intern-slice-metric
        (ci.intern-profile-slice-value
          (compiler-driver-profile-intern-metrics-address state)))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-profile-phase-start-intern-generated-metric
        (ci.intern-profile-generated-value
          (compiler-driver-profile-intern-metrics-address state)))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-profile-phase-start-intern-render-metric
        (ci.intern-profile-render-value
          (compiler-driver-profile-intern-metrics-address state)))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-profile-phase-start-intern-lookup-metric
        (ci.intern-profile-lookup-value
          (compiler-driver-profile-intern-metrics-address state)))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
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
      [intern-metrics-address : u64
        (compiler-driver-profile-intern-metrics-address state)]
      [end-intern : i64 (ci.intern-profile-intern-value intern-metrics-address)]
      [end-intern-slice : i64
        (ci.intern-profile-slice-value intern-metrics-address)]
      [end-intern-generated : i64
        (ci.intern-profile-generated-value intern-metrics-address)]
      [end-intern-render : i64
        (ci.intern-profile-render-value intern-metrics-address)]
      [end-intern-lookup : i64
        (ci.intern-profile-lookup-value intern-metrics-address)]
      [end-intern-pool-len : i64 (ci.intern-pool-len)]
      [peak-delta : i64
        (compiler-driver-profile-nonnegative
          (-
            end-peak
            (compiler-driver-profile-value
              (profile_state.compiler-profile-state-shared-view state)
              compiler-driver-profile-phase-start-live-metric)))]
      (begin
        (compiler-driver-profile-set!
          (profile_state.compiler-profile-state-shared-view state)
          compiler-driver-batch-profile-best-peak-metric
          (compiler-driver-profile-max
            (compiler-driver-profile-value
              (profile_state.compiler-profile-state-shared-view state)
              compiler-driver-batch-profile-best-peak-metric)
            peak-delta))
        (io.print-error
          (compiler-driver-profile-line
            (owned_view.compiler-owned-shared-view phase)
            (-
              end-ms
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-profile-phase-start-ms-metric))
            (-
              end-total
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-profile-phase-start-total-metric))
            (-
              end-live
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-profile-phase-start-live-metric))
            peak-delta))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (str_cat.str-cat
              "compile-profile-detail|intern.phase|"
              (owned_view.compiler-owned-shared-view phase)
              "|"
              (string.int->string
                (-
                  end-intern
                  (compiler-driver-profile-value
                    (profile_state.compiler-profile-state-shared-view state)
                    compiler-driver-profile-phase-start-intern-metric)))
              "\n")))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (str_cat.str-cat
              "compile-profile-detail|intern.phase.slice|"
              (owned_view.compiler-owned-shared-view phase)
              "|"
              (string.int->string
                (-
                  end-intern-slice
                  (compiler-driver-profile-value
                    (profile_state.compiler-profile-state-shared-view state)
                    compiler-driver-profile-phase-start-intern-slice-metric)))
              "\n")))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (str_cat.str-cat
              "compile-profile-detail|intern.phase.generated|"
              (owned_view.compiler-owned-shared-view phase)
              "|"
              (string.int->string
                (-
                  end-intern-generated
                  (compiler-driver-profile-value
                    (profile_state.compiler-profile-state-shared-view state)
                    compiler-driver-profile-phase-start-intern-generated-metric)))
              "\n")))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (str_cat.str-cat
              "compile-profile-detail|intern.phase.render|"
              (owned_view.compiler-owned-shared-view phase)
              "|"
              (string.int->string
                (-
                  end-intern-render
                  (compiler-driver-profile-value
                    (profile_state.compiler-profile-state-shared-view state)
                    compiler-driver-profile-phase-start-intern-render-metric)))
              "\n")))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (str_cat.str-cat
              "compile-profile-detail|intern.phase.lookup|"
              (owned_view.compiler-owned-shared-view phase)
              "|"
              (string.int->string
                (-
                  end-intern-lookup
                  (compiler-driver-profile-value
                    (profile_state.compiler-profile-state-shared-view state)
                    compiler-driver-profile-phase-start-intern-lookup-metric)))
              "\n")))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (str_cat.str-cat
              "compile-profile-detail|intern.phase.pool|"
              (owned_view.compiler-owned-shared-view phase)
              "|"
              (string.int->string
                (-
                  end-intern-pool-len
                  (compiler-driver-profile-value
                    (profile_state.compiler-profile-state-shared-view state)
                    compiler-driver-profile-phase-start-intern-pool-len-metric)))
              "\n")))
        (cfg
          compile-profile-summary
          unit
          (io.print-error
            (str_cat.str-cat
              "compile-profile-detail|intern.phase.invalid_str_ids|"
              (owned_view.compiler-owned-shared-view phase)
              "|"
              (string.int->string
                (ci.intern-profile-invalid-str-value intern-metrics-address))
              "\n")))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-total
    [state : profile_state.CompilerProfileState]) : unit
    (begin
      (compiler-driver-profile-reset-prelude!
        (profile_state.compiler-profile-state-shared-view state))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-profile-total-start-ms-metric
        (profile.now-ms))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-profile-total-start-total-metric
        (profile.alloc-total))
      (compiler-driver-profile-set!
        (profile_state.compiler-profile-state-shared-view state)
        compiler-driver-profile-total-start-live-metric
        (profile.alloc-live))
      (profile.compile-wide-peak-start!)
      (ci.intern-profile-reset!
        (compiler-driver-profile-intern-metrics-address state))
      (compiler_ctfe.ctfe-env-profile-reset!)
      (cfg
        compile-profile-summary
        (begin
          (compiler_optimize.compiler-opt-profile-summary-reset!
            (profile_state.compiler-profile-state-shared-view state))
          (compiler_backend.compiler-backend-profile-summary-reset!
            (profile_state.compiler-profile-state-shared-view state)))
        unit)
      (io.print-error
        "compile-profile|phase|elapsed_ms|alloc_delta_bytes|live_delta_bytes|peak_live_delta_bytes\n")
      (cfg
        compile-profile-summary
        (io.print-error
          "compile-profile-summary|scope|kind|rank|name|elapsed_ms|calls\n")
        unit)
      (compiler-driver-profile-start-phase
        (profile_state.compiler-profile-state-shared-view state)))))

(cfg
  compile-profile
  (define (compiler-driver-profile-prelude-counters
    [state : profile_state.CompilerProfileState]) : unit
    (cfg
      compile-profile-summary
      unit
      (begin
        (io.print-error
          (str_cat.str-cat
            "compile-profile-detail|prelude.source_pipeline_entries|"
            (string.int->string
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-profile-prelude-source-pipeline-entries-metric))
            "\n"))
        (io.print-error
          (str_cat.str-cat
            "compile-profile-detail|prelude.hydrations|"
            (string.int->string
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-profile-prelude-hydrations-metric))
            "\n"))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-intern-line [name : String] [value : i64]) : unit
    (io.print-error
      (str_cat.str-cat
        "compile-profile|intern."
        name
        (compiler-driver-profile-field value)
        "|0|0|0\n"))))

(cfg
  compile-profile
  (define (compiler-driver-profile-ctfe-env-line [name : String] [value : i64]) : unit
    (io.print-error
      (str_cat.str-cat
        "compile-profile|ctfe_env."
        name
        (compiler-driver-profile-field value)
        "|0|0|0\n"))))

(cfg
  compile-profile
  (define (compiler-driver-profile-finish-total
    [state : profile_state.CompilerProfileState]) : unit
    (let
      [compile-wide-peak : i64 (profile.compile-wide-peak-finish!)]
      [intern-metrics-address : u64
        (compiler-driver-profile-intern-metrics-address state)]
      (begin
        (io.print-error
          (compiler-driver-profile-line
            "total"
            (-
              (profile.now-ms)
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-profile-total-start-ms-metric))
            (-
              (profile.alloc-total)
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-profile-total-start-total-metric))
            (-
              (profile.alloc-live)
              (compiler-driver-profile-value
                (profile_state.compiler-profile-state-shared-view state)
                compiler-driver-profile-total-start-live-metric))
            compile-wide-peak))
        (compiler-driver-profile-intern-line
          "hash_words"
          (ci.intern-profile-hash-words-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "intern_calls"
          (ci.intern-profile-intern-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "slice_calls"
          (ci.intern-profile-slice-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "generated_allocations"
          (ci.intern-profile-generated-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "render_calls"
          (ci.intern-profile-render-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "lookup_calls"
          (ci.intern-profile-lookup-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "source_bytes"
          (ci.intern-profile-source-bytes-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "source_symbols"
          (ci.intern-profile-source-symbol-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "source_symbol_bytes"
          (ci.intern-profile-source-symbol-bytes-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "slice_bytes"
          (ci.intern-profile-slice-bytes-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "slice_hits"
          (ci.intern-profile-slice-hit-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "slice_misses"
          (ci.intern-profile-slice-miss-value intern-metrics-address))
        (compiler-driver-profile-intern-line
          "records.source_live"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-source-record-live-metric))
        (compiler-driver-profile-intern-line
          "records.source_capacity"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-source-record-capacity-metric))
        (compiler-driver-profile-intern-line
          "records.generated_live"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-generated-record-live-metric))
        (compiler-driver-profile-intern-line
          "records.generated_capacity"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-generated-record-capacity-metric))
        (compiler-driver-profile-intern-line
          "records.source_resizes"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-source-record-resize-metric))
        (compiler-driver-profile-intern-line
          "records.generated_resizes"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-generated-record-resize-metric))
        (compiler-driver-profile-intern-line
          "records.reserved_bytes"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-record-reserved-bytes-metric))
        (compiler-driver-profile-intern-line
          "source_map.live"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-source-map-live-metric))
        (compiler-driver-profile-intern-line
          "source_map.capacity"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-source-map-capacity-metric))
        (compiler-driver-profile-intern-line
          "source_map.probes_total"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-source-map-probe-total-metric))
        (compiler-driver-profile-intern-line
          "source_map.probe_max"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-source-map-probe-max-metric))
        (compiler-driver-profile-intern-line
          "source_map.resizes"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-source-map-resize-metric))
        (compiler-driver-profile-intern-line
          "source_map.reserved_bytes"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-source-map-reserved-bytes-metric))
        (compiler-driver-profile-intern-line
          "canonical_map.live"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-canonical-map-live-metric))
        (compiler-driver-profile-intern-line
          "canonical_map.capacity"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-canonical-map-capacity-metric))
        (compiler-driver-profile-intern-line
          "canonical_map.probes_total"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-canonical-map-probe-total-metric))
        (compiler-driver-profile-intern-line
          "canonical_map.probe_max"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-canonical-map-probe-max-metric))
        (compiler-driver-profile-intern-line
          "canonical_map.resizes"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-canonical-map-resize-metric))
        (compiler-driver-profile-intern-line
          "canonical_map.reserved_bytes"
          (ci.intern-profile-value
            intern-metrics-address
            ci.intern-profile-canonical-map-reserved-bytes-metric))
        (compiler-driver-profile-ctfe-env-line
          "binding_appends"
          (compiler_ctfe.ctfe-env-profile-binding-appends-value))
        (compiler-driver-profile-ctfe-env-line
          "value_lookups"
          (compiler_ctfe.ctfe-env-profile-value-lookups-value))
        (compiler-driver-profile-ctfe-env-line
          "type_lookups"
          (compiler_ctfe.ctfe-env-profile-type-lookups-value))
        (compiler-driver-profile-ctfe-env-line
          "lookup_steps"
          (compiler_ctfe.ctfe-env-profile-lookup-steps-value))
        (compiler-driver-profile-ctfe-env-line
          "local_set_calls"
          (compiler_ctfe.ctfe-env-profile-local-set-calls-value))
        (compiler-driver-profile-ctfe-env-line
          "local_set_steps"
          (compiler_ctfe.ctfe-env-profile-local-set-steps-value))
        (compiler-driver-profile-ctfe-env-line
          "arena_roots"
          (compiler_ctfe.ctfe-env-profile-arena-roots-value))
        (compiler-driver-profile-ctfe-env-line
          "arena_grows"
          (compiler_ctfe.ctfe-env-profile-arena-grows-value))))))

(define (compiler-driver-lower-mode-for-target
  [target : compiler_backend.CompilerBackendTarget]
  [mode : compiler_backend.CompilerBackendMode]) : compiler_lower.CompilerLowerMode
  (match mode
    [(compiler_backend.CompilerBackendMode.Avx2)
      (match target
        [(compiler_backend.CompilerBackendTarget.Linux)
          (compiler_lower.CompilerLowerMode.LinuxAvx2)]
        [(compiler_backend.CompilerBackendTarget.Windows)
          (compiler_lower.CompilerLowerMode.WindowsAvx2)])]
    [(compiler_backend.CompilerBackendMode.Avx512)
      (match target
        [(compiler_backend.CompilerBackendTarget.Linux)
          (compiler_lower.CompilerLowerMode.LinuxAvx512)]
        [(compiler_backend.CompilerBackendTarget.Windows)
          (compiler_lower.CompilerLowerMode.WindowsAvx512)])]
    [_
      (match target
        [(compiler_backend.CompilerBackendTarget.Linux)
          (compiler_lower.CompilerLowerMode.LinuxScalar)]
        [(compiler_backend.CompilerBackendTarget.Windows)
          (compiler_lower.CompilerLowerMode.WindowsScalar)])]))

(define (compiler-driver-enable-linux-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-enable-linux-cfgs cfgs))

(define (compiler-driver-enable-windows-cfgs [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-enable-windows-cfgs cfgs))

(define (compiler-driver-enable-linux-cfgs-with-intern-state
  [cfgs : sym_i64_env.SymI64Env]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-enable-linux-cfgs-with-intern-state
    cfgs
    intern-state))

(define (compiler-driver-enable-windows-cfgs-with-intern-state
  [cfgs : sym_i64_env.SymI64Env]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-enable-windows-cfgs-with-intern-state
    cfgs
    intern-state))

(define (compiler-driver-target-cfgs
  [target : compiler_backend.CompilerBackendTarget]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (match target
      [(compiler_backend.CompilerBackendTarget.Linux)
        (compiler-driver-enable-linux-cfgs cfgs)]
      [(compiler_backend.CompilerBackendTarget.Windows)
        (compiler-driver-enable-windows-cfgs cfgs)])))

(define (compiler-driver-state-target-cfgs
  [state : CompilerDriverState]
  [target : compiler_backend.CompilerBackendTarget]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match target
    [(compiler_backend.CompilerBackendTarget.Linux)
      (compiler-driver-enable-linux-cfgs-with-intern-state
        cfgs
        (&mut (array-ref state.intern-state 0)))]
    [(compiler_backend.CompilerBackendTarget.Windows)
      (compiler-driver-enable-windows-cfgs-with-intern-state
        cfgs
        (&mut (array-ref state.intern-state 0)))]))

(define (compiler-driver-emit-lowered-with-level
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [opt-level : i64]) : ResultCompilerDriver
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    [backend-state : compiler_backend.CompilerBackendState
      (compiler_backend.compiler-backend-state-new-with-metrics
        (ci.intern-compat-state-capture-active)
        (profile_state.compiler-profile-state-metrics
          (owned_view.compiler-owned-shared-view profile-state)))]
    (compiler-driver-emit-lowered-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
      (compiler_ast_types.ast-node-pool-reader-context-current)
      input-path
      program
      spans
      target
      has-target
      (compiler_backend.CompilerBackendMode.Scalar)
      opt-level
      true
      false
      profile-state
      backend-state
      (compiler_typecheck_core.tc-serial-job-state))))

;; The lowered IR functions live in a dedicated arena
;; (lower-ir-arena); at opt levels >= 1 the optimizer deep-clones every
;; surviving function out of it, so the arena is dead weight (~172MB on a
;; cli.tl self-compile) once optimization returns. At level 0 the lowered
;; program flows to the backend unchanged and the arena must stay alive.
(define (compiler-driver-release-lowered-ir! [opt-level : i64]) : unit
  (if (>= opt-level 1)
    (compiler_lower.lower-ir-arena-release!)
    unit))

;; Once lowering has produced IR, optimizer/backend no longer consult the full
;; typecheck/macro CTFE caches. Drop them before the backend's large assembly
;; buffers are allocated, but retain the compact definition-site alias table:
;; package surface emission can still expand a dependent macro under this same
;; source-name owner. The lower scratch arena is function-local: escaped IR
;; lives outside it, so it can be released before optimize/backend instead of
;; overlapping with backend assembly buffers.
(define (compiler-driver-release-typecheck-caches-after-lower-for-job!
  [typecheck-state : compiler_typecheck_core.TcJobState]) : unit
  (begin
    (compiler_typecheck_core.compiler-typecheck-reset-file-state-preserving-lazy-imports-for-job!
      typecheck-state)
    (compiler_lower.lower-scratch-arena-release!)))

;; Serial compatibility adapter. State-owned compiler entrypoints carry their
;; typecheck job through ResultCompilerDriverLowered and use the explicit form.
(define (compiler-driver-release-typecheck-caches-after-lower!) : unit
  (compiler-driver-release-typecheck-caches-after-lower-for-job!
    (compiler_typecheck_core.tc-serial-job-state)))

;; Package builds may run TLci, direct-object, and doctest passes after an
;; assembly emit while keeping the loaded AST alive. A full file-state reset
;; would invalidate those loaded pools, but the lowered IR has already been
;; consumed by the backend and can be dropped at any opt level.
(define (compiler-driver-release-lower-arenas-after-emit!) : unit
  (compiler_lower.lower-arenas-release!))

(define (compiler-driver-representation-index-for-backend
  [pools : compiler_ast_types.AstNodePoolContext]
  [program : compiler_ir_types.CompilerIrProgram]
  [backend-state : compiler_backend.CompilerBackendState]) : compiler_ir_types.CompilerIrRepresentationIndex
  (let
    [owner : arena.Arena
      (compiler_backend.compiler-backend-state-prepare-representation-arena!
        backend-state)]
    [representations : compiler_ir_types.CompilerIrRepresentationIndex
      (in-arena
        owner
        (compiler_ir_types.compiler-ir-representation-index-build
          (compiler_ast_types.ast-node-pool-context-type-segment-bases pools)
          program))]
    (begin
      (compiler_backend.compiler-backend-state-set-representations!
        backend-state
        (owned_view.compiler-owned-shared-view representations))
      representations)))

(define (compiler-driver-emit-lowered-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : compiler_backend.CompilerBackendState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerDriver
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriver.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower-for-job!
        typecheck-state)
      (compiler-driver-retire-frontend-arena!)
      (cfg
        compile-profile
        (compiler-driver-profile-start-phase
          (profile_state.compiler-profile-state-shared-view profile-state)))
      (match (compiler_optimize.optimize-program-with-spans-and-pools-and-level-and-profile-state-and-representations
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view program)
        spans
        opt-level
        (profile_state.compiler-profile-state-shared-view profile-state)
        (compiler-driver-representation-index-for-backend
          (owned_view.compiler-owned-shared-view pools)
          (owned_view.compiler-owned-shared-view program)
          backend-state))
        [(compiler_optimize.CompilerOptimizedProgram.Program
            optimized
            optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase
                (profile_state.compiler-profile-state-shared-view profile-state)
                "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerDriver.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
              (begin
                (compiler_backend.compiler-backend-state-set-scalar-registers-enabled!
                  backend-state
                  (>= opt-level 2))
                (cfg
                  compile-profile
                  (compiler-driver-profile-start-phase
                    (profile_state.compiler-profile-state-shared-view
                      profile-state)))
                (match (if has-target
                  (compiler_backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                    backend-state
                    pools
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    (profile_state.compiler-profile-state-shared-view
                      profile-state))
                  (compiler_backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                    backend-state
                    pools
                    optimized
                    (compiler_backend.CompilerBackendTarget.Linux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    (profile_state.compiler-profile-state-shared-view
                      profile-state)))
                  [(compiler_backend.ResultCompilerBackend.Ok asm)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          (profile_state.compiler-profile-state-shared-view
                            profile-state)
                          "backend"))
                      (ResultCompilerDriver.Ok asm))]
                  [(compiler_backend.ResultCompilerBackend.Err diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          (profile_state.compiler-profile-state-shared-view
                            profile-state)
                          "backend"))
                      (ResultCompilerDriver.Err
                        (box
                          (compiler_diagnostic.compiler-diagnostic-with-fallback-path
                            (owned_view.compiler-owned-box-shared-view diag)
                            input-path))))]))))]))))

(define (compiler-driver-emit-lowered-buffer-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : compiler_backend.CompilerBackendState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerDriverBuffer
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriverBuffer.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower-for-job!
        typecheck-state)
      (compiler-driver-retire-frontend-arena!)
      (cfg
        compile-profile
        (compiler-driver-profile-start-phase
          (profile_state.compiler-profile-state-shared-view profile-state)))
      (match (compiler_optimize.optimize-program-with-spans-and-pools-and-level-and-profile-state-and-representations
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view program)
        spans
        opt-level
        (profile_state.compiler-profile-state-shared-view profile-state)
        (compiler-driver-representation-index-for-backend
          (owned_view.compiler-owned-shared-view pools)
          (owned_view.compiler-owned-shared-view program)
          backend-state))
        [(compiler_optimize.CompilerOptimizedProgram.Program
            optimized
            optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase
                (profile_state.compiler-profile-state-shared-view profile-state)
                "optimize"))
            (compiler-driver-allocation-profile-snapshot-for-job!
              typecheck-state
              "optimize")
            (compiler-driver-release-lowered-ir! opt-level)
            (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerDriverBuffer.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
              (begin
                (compiler_backend.compiler-backend-state-set-scalar-registers-enabled!
                  backend-state
                  (>= opt-level 2))
                (cfg
                  compile-profile
                  (compiler-driver-profile-start-phase
                    (profile_state.compiler-profile-state-shared-view
                      profile-state)))
                (match (if has-target
                  (compiler_backend.compiler-backend-emit-program-target-with-mode-final-buffer-with-pools-and-crt-and-profile-state-backend-state
                    backend-state
                    pools
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    (profile_state.compiler-profile-state-shared-view
                      profile-state))
                  (compiler_backend.compiler-backend-emit-program-target-with-mode-final-buffer-with-pools-and-crt-and-profile-state-backend-state
                    backend-state
                    pools
                    optimized
                    (compiler_backend.CompilerBackendTarget.Linux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    (profile_state.compiler-profile-state-shared-view
                      profile-state)))
                  [(compiler_backend.ResultCompilerBackendBuffer.Ok asm)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          (profile_state.compiler-profile-state-shared-view
                            profile-state)
                          "backend"))
                      (compiler-driver-allocation-profile-snapshot-for-job!
                        typecheck-state
                        "backend")
                      (compiler-driver-allocation-profile-backend-output-snapshot!
                        backend-state)
                      (ResultCompilerDriverBuffer.Ok asm))]
                  [(compiler_backend.ResultCompilerBackendBuffer.Err diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          (profile_state.compiler-profile-state-shared-view
                            profile-state)
                          "backend"))
                      (compiler-driver-allocation-profile-snapshot-for-job!
                        typecheck-state
                        "backend")
                      (compiler-driver-allocation-profile-backend-output-snapshot!
                        backend-state)
                      (ResultCompilerDriverBuffer.Err
                        (box
                          (compiler_diagnostic.compiler-diagnostic-with-fallback-path
                            (owned_view.compiler-owned-box-shared-view diag)
                            input-path))))]))))]))))

(define (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : compiler_backend.CompilerBackendState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerDriverObject
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriverObject.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower-for-job!
        typecheck-state)
      (compiler-driver-retire-frontend-arena!)
      (cfg
        compile-profile
        (compiler-driver-profile-start-phase
          (profile_state.compiler-profile-state-shared-view profile-state)))
      (match (compiler_optimize.optimize-program-with-spans-and-pools-and-level-and-profile-state-and-representations
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view program)
        spans
        opt-level
        (profile_state.compiler-profile-state-shared-view profile-state)
        (compiler-driver-representation-index-for-backend
          (owned_view.compiler-owned-shared-view pools)
          (owned_view.compiler-owned-shared-view program)
          backend-state))
        [(compiler_optimize.CompilerOptimizedProgram.Program
            optimized
            optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase
                (profile_state.compiler-profile-state-shared-view profile-state)
                "optimize"))
            (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
              (begin
                (compiler-driver-release-lowered-ir! opt-level)
                (ResultCompilerDriverObject.Err
                  (box
                    (compiler-driver-ty-node-pool-exhausted-diagnostic
                      input-path))))
              (begin
                (compiler_backend.compiler-backend-state-set-scalar-registers-enabled!
                  backend-state
                  (>= opt-level 2))
                (match (compiler_backend.compiler-backend-object-program-eligibility
                  backend-state
                  (owned_view.compiler-owned-shared-view optimized))
                  [(compiler_backend.CompilerBackendObjectEligibility.Unsupported
                      category)
                    ;; Preserve the original lowered program for the caller's
                    ;; assembly fallback. At optimized levels the release must
                    ;; happen only after object eligibility is established.
                    (ResultCompilerDriverObject.Unavailable category)]
                  [(compiler_backend.CompilerBackendObjectEligibility.Eligible)
                    (begin
                      (compiler-driver-release-lowered-ir! opt-level)
                      (cfg
                        compile-profile
                        (compiler-driver-profile-start-phase
                          (profile_state.compiler-profile-state-shared-view
                            profile-state)))
                      (match (if has-target
                        (compiler_backend.compiler-backend-emit-program-object-image-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                          backend-state
                          pools
                          optimized
                          target
                          mode
                          optimized-spans
                          emit-entry
                          crt-entry
                          (profile_state.compiler-profile-state-shared-view
                            profile-state))
                        (compiler_backend.compiler-backend-emit-program-object-image-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                          backend-state
                          pools
                          optimized
                          (compiler_backend.CompilerBackendTarget.Linux)
                          mode
                          optimized-spans
                          emit-entry
                          crt-entry
                          (profile_state.compiler-profile-state-shared-view
                            profile-state)))
                        [(compiler_backend.ResultCompilerBackendObject.Ok image)
                          (begin
                            (cfg
                              compile-profile
                              (compiler-driver-profile-finish-phase
                                (profile_state.compiler-profile-state-shared-view
                                  profile-state)
                                "backend"))
                            (ResultCompilerDriverObject.Ok image))]
                        [(compiler_backend.ResultCompilerBackendObject.Err diag)
                          (begin
                            (cfg
                              compile-profile
                              (compiler-driver-profile-finish-phase
                                (profile_state.compiler-profile-state-shared-view
                                  profile-state)
                                "backend"))
                            (ResultCompilerDriverObject.Err
                              (box
                                (compiler_diagnostic.compiler-diagnostic-with-fallback-path
                                  (owned_view.compiler-owned-box-shared-view
                                    diag)
                                  input-path))))]))]))))]))))

(define (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt-and-profile-state
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverObject
  (let
    [backend-state : compiler_backend.CompilerBackendState
      (compiler_backend.compiler-backend-state-new-with-metrics
        (ci.intern-compat-state-capture-active)
        (profile_state.compiler-profile-state-metrics
          (owned_view.compiler-owned-shared-view profile-state)))]
    (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
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
      (profile_state.compiler-profile-state-shared-view profile-state)
      backend-state
      (compiler_typecheck_core.tc-serial-job-state))))

(define (compiler-driver-emit-lowered-package-runtime-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : compiler_backend.CompilerBackendTarget]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : compiler_backend.CompilerBackendState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerDriverPackageRuntime
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriverPackageRuntime.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower-for-job!
        typecheck-state)
      (compiler-driver-retire-frontend-arena!)
      (cfg
        compile-profile
        (compiler-driver-profile-start-phase
          (profile_state.compiler-profile-state-shared-view profile-state)))
      (match (compiler_optimize.optimize-program-with-spans-and-pools-and-level-and-profile-state-and-representations
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view program)
        spans
        opt-level
        (profile_state.compiler-profile-state-shared-view profile-state)
        (compiler-driver-representation-index-for-backend
          (owned_view.compiler-owned-shared-view pools)
          (owned_view.compiler-owned-shared-view program)
          backend-state))
        [(compiler_optimize.CompilerOptimizedProgram.Program
            optimized
            optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase
                (profile_state.compiler-profile-state-shared-view profile-state)
                "optimize"))
            (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
              (begin
                (compiler-driver-release-lowered-ir! opt-level)
                (ResultCompilerDriverPackageRuntime.Err
                  (box
                    (compiler-driver-ty-node-pool-exhausted-diagnostic
                      input-path))))
              (begin
                (compiler_backend.compiler-backend-state-set-scalar-registers-enabled!
                  backend-state
                  (>= opt-level 2))
                (match (compiler_backend.compiler-backend-object-program-eligibility
                  backend-state
                  (owned_view.compiler-owned-shared-view optimized))
                  [(compiler_backend.CompilerBackendObjectEligibility.Unsupported
                      category)
                    (begin
                      (compiler-driver-release-lowered-ir! opt-level)
                      (cfg
                        compile-profile
                        (compiler-driver-profile-start-phase
                          (profile_state.compiler-profile-state-shared-view
                            profile-state)))
                      (match (compiler_backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                        backend-state
                        pools
                        optimized
                        target
                        mode
                        optimized-spans
                        emit-entry
                        crt-entry
                        (profile_state.compiler-profile-state-shared-view
                          profile-state))
                        [(compiler_backend.ResultCompilerBackend.Ok asm)
                          (begin
                            (cfg
                              compile-profile
                              (compiler-driver-profile-finish-phase
                                (profile_state.compiler-profile-state-shared-view
                                  profile-state)
                                "backend"))
                            (ResultCompilerDriverPackageRuntime.Assembly
                              asm
                              category))]
                        [(compiler_backend.ResultCompilerBackend.Err diag)
                          (begin
                            (cfg
                              compile-profile
                              (compiler-driver-profile-finish-phase
                                (profile_state.compiler-profile-state-shared-view
                                  profile-state)
                                "backend"))
                            (ResultCompilerDriverPackageRuntime.Err
                              (box
                                (compiler_diagnostic.compiler-diagnostic-with-fallback-path
                                  (owned_view.compiler-owned-box-shared-view
                                    diag)
                                  input-path))))]))]
                  [(compiler_backend.CompilerBackendObjectEligibility.Eligible)
                    (begin
                      (compiler-driver-release-lowered-ir! opt-level)
                      (cfg
                        compile-profile
                        (compiler-driver-profile-start-phase
                          (profile_state.compiler-profile-state-shared-view
                            profile-state)))
                      (match (compiler_backend.compiler-backend-emit-program-object-image-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                        backend-state
                        (owned_view.compiler-owned-shared-view pools)
                        (owned_view.compiler-owned-shared-view optimized)
                        (owned_view.compiler-owned-shared-view target)
                        (owned_view.compiler-owned-shared-view mode)
                        (owned_view.compiler-owned-shared-view optimized-spans)
                        emit-entry
                        crt-entry
                        (profile_state.compiler-profile-state-shared-view
                          profile-state))
                        [(compiler_backend.ResultCompilerBackendObject.Ok image)
                          (begin
                            (cfg
                              compile-profile
                              (compiler-driver-profile-finish-phase
                                (profile_state.compiler-profile-state-shared-view
                                  profile-state)
                                "backend.object-image"))
                            (let
                              [side-backend-state : compiler_backend.CompilerBackendState
                                (compiler_backend.compiler-backend-state-new-with-metrics
                                  (ci.intern-compat-state-capture-active)
                                  (profile_state.compiler-profile-state-metrics
                                    (profile_state.compiler-profile-state-shared-view
                                      profile-state)))]
                              (begin
                                (compiler_backend.compiler-backend-state-set-scalar-registers-enabled!
                                  side-backend-state
                                  (>= opt-level 2))
                                (cfg
                                  compile-profile
                                  (compiler-driver-profile-start-phase
                                    (profile_state.compiler-profile-state-shared-view
                                      profile-state)))
                                (match (compiler_backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                                  side-backend-state
                                  pools
                                  optimized
                                  target
                                  mode
                                  optimized-spans
                                  emit-entry
                                  crt-entry
                                  (profile_state.compiler-profile-state-shared-view
                                    profile-state))
                                  [(compiler_backend.ResultCompilerBackend.Ok
                                      asm)
                                    (begin
                                      (cfg
                                        compile-profile
                                        (compiler-driver-profile-finish-phase
                                          (profile_state.compiler-profile-state-shared-view
                                            profile-state)
                                          "backend.side-assembly"))
                                      (ResultCompilerDriverPackageRuntime.Object
                                        image
                                        asm))]
                                  [(compiler_backend.ResultCompilerBackend.Err
                                      diag)
                                    (begin
                                      (cfg
                                        compile-profile
                                        (compiler-driver-profile-finish-phase
                                          (profile_state.compiler-profile-state-shared-view
                                            profile-state)
                                          "backend.side-assembly"))
                                      (ResultCompilerDriverPackageRuntime.Err
                                        (box
                                          (compiler_diagnostic.compiler-diagnostic-with-fallback-path
                                            (owned_view.compiler-owned-box-shared-view
                                              diag)
                                            input-path))))]))))]
                        [(compiler_backend.ResultCompilerBackendObject.Err diag)
                          (begin
                            (cfg
                              compile-profile
                              (compiler-driver-profile-finish-phase
                                (profile_state.compiler-profile-state-shared-view
                                  profile-state)
                                "backend"))
                            (ResultCompilerDriverPackageRuntime.Err
                              (box
                                (compiler_diagnostic.compiler-diagnostic-with-fallback-path
                                  (owned_view.compiler-owned-box-shared-view
                                    diag)
                                  input-path))))]))]))))]))))

(define (compiler-driver-emit-lowered-pic-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : compiler_backend.CompilerBackendState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerDriverPic
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriverPic.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower-for-job!
        typecheck-state)
      (compiler-driver-retire-frontend-arena!)
      (cfg
        compile-profile
        (compiler-driver-profile-start-phase
          (profile_state.compiler-profile-state-shared-view profile-state)))
      (match (compiler_optimize.optimize-program-with-spans-and-pools-and-level-and-profile-state-and-representations
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view program)
        spans
        opt-level
        (profile_state.compiler-profile-state-shared-view profile-state)
        (compiler-driver-representation-index-for-backend
          (owned_view.compiler-owned-shared-view pools)
          (owned_view.compiler-owned-shared-view program)
          backend-state))
        [(compiler_optimize.CompilerOptimizedProgram.Program
            optimized
            optimized-spans)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase
                (profile_state.compiler-profile-state-shared-view profile-state)
                "optimize"))
            (compiler-driver-release-lowered-ir! opt-level)
            (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerDriverPic.Err
                (box
                  (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))
              (begin
                (compiler_backend.compiler-backend-state-set-scalar-registers-enabled!
                  backend-state
                  (>= opt-level 2))
                (cfg
                  compile-profile
                  (compiler-driver-profile-start-phase
                    (profile_state.compiler-profile-state-shared-view
                      profile-state)))
                (match (if has-target
                  (compiler_backend.compiler-backend-emit-program-pic-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                    backend-state
                    pools
                    optimized
                    target
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    (profile_state.compiler-profile-state-shared-view
                      profile-state))
                  (compiler_backend.compiler-backend-emit-program-pic-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                    backend-state
                    pools
                    optimized
                    (compiler_backend.CompilerBackendTarget.Linux)
                    mode
                    optimized-spans
                    emit-entry
                    crt-entry
                    (profile_state.compiler-profile-state-shared-view
                      profile-state)))
                  [(compiler_backend.ResultCompilerBackendPic.Ok output)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          (profile_state.compiler-profile-state-shared-view
                            profile-state)
                          "backend"))
                      (ResultCompilerDriverPic.Ok output))]
                  [(compiler_backend.ResultCompilerBackendPic.Err diag)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          (profile_state.compiler-profile-state-shared-view
                            profile-state)
                          "backend"))
                      (ResultCompilerDriverPic.Err
                        (box
                          (compiler_diagnostic.compiler-diagnostic-with-fallback-path
                            (owned_view.compiler-owned-box-shared-view diag)
                            input-path))))]))))]))))

;; Serial/test compatibility adapters. Driver-owned compile paths carry the
;; state from ResultCompilerDriverLowered into the explicit variants above.
(define (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [mode : compiler_backend.CompilerBackendMode]
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

(define (compiler-driver-restore-arena-owner-current! [return-arena : i64]) : unit
  ;; Public handles remain stable owner roots across growth, so restoring the
  ;; captured handle resumes the complete chain directly.
  (unsafe
    (arena.tl_arena_set return-arena)))

(define (compiler-driver-restore-frontend-return-arena!) : unit
  (if (= compiler-driver-pending-frontend-return-arena 0)
    unit
    (let
      [return-arena : i64 compiler-driver-pending-frontend-return-arena]
      (begin
        (set! compiler-driver-pending-frontend-return-arena 0)
        (compiler-driver-restore-arena-owner-current! return-arena)))))

;; Lowering can report an error while the checked-pool handoff owns a temporary
;; macro frontend that abort must retire. Deep-copy the diagnostic into the
;; compile state's retained surface before that transition runs; the result can
;; then cross the load/lower boundary without borrowing the retiring arena.
(define (compiler-driver-diagnostic-copy-to-state-surface
  [state : CompilerDriverState]
  [diag : (Box compiler_diagnostic.CompilerDiagnostic)]) : (Box
    compiler_diagnostic.CompilerDiagnostic)
  (in-arena
    (arena.Arena (compiler-driver-state-surface-arena state))
    (box
      (compiler_diagnostic.compiler-diagnostic-copy
        (owned_view.compiler-owned-box-shared-view diag)))))

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
        (compiler_lower.lower-reset-file-state!)
        (unsafe
          (begin
            (set! compiler-driver-pending-retired-source-arena 0)
            (set! compiler-driver-pending-retired-source-expr-storage-arena 0)
            (set! compiler-driver-pending-retired-source-type-storage-arena 0)
            (compiler_ast_types.ast-node-pool-storage-arenas-destroy!
              retire-expr-storage-arena
              retire-type-storage-arena
              retire-arena)
            (arena.tl_arena_destroy retire-arena)
            (arena.tl_arena_set retained-arena)))))))

(define (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriver
  (match lowered
    [(ResultCompilerDriverLowered.Ok
        program
        spans
        pools
        profile-state
        backend-state
        typecheck-state)
      (let
        [_profile-program-start : unit
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase
              (profile_state.compiler-profile-state-shared-view profile-state))
            unit)]
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              (owned_view.compiler-owned-shared-view pools)
              program)
            program)]
        [_profile-program-finish : unit
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (profile_state.compiler-profile-state-shared-view profile-state)
              "retain.program")
            unit)]
        [_profile-spans-start : unit
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase
              (profile_state.compiler-profile-state-shared-view profile-state))
            unit)]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [_profile-spans-finish : unit
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (profile_state.compiler-profile-state-shared-view profile-state)
              "retain.spans")
            unit)]
        [out : ResultCompilerDriver
          (begin
            (compiler_ast_types.ast-node-pool-reader-use!
              (owned_view.compiler-owned-shared-view pools))
            (cfg
              compile-profile
              (compiler-driver-profile-start-phase
                (profile_state.compiler-profile-state-shared-view profile-state)))
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase
                (profile_state.compiler-profile-state-shared-view profile-state)
                "retain.release"))
            (compiler-driver-emit-lowered-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
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
              profile-state
              backend-state
              typecheck-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (compiler_ast_types.ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriver.Err diag))]))

(define (compiler-driver-emit-lowered-result-buffer-with-level-mode-and-entry
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]) : ResultCompilerDriverBuffer
  (match lowered
    [(ResultCompilerDriverLowered.Ok
        program
        spans
        pools
        profile-state
        backend-state
        typecheck-state)
      (let
        [_profile-program-start : unit
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase
              (profile_state.compiler-profile-state-shared-view profile-state))
            unit)]
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              (owned_view.compiler-owned-shared-view pools)
              program)
            program)]
        [_profile-program-finish : unit
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (profile_state.compiler-profile-state-shared-view profile-state)
              "retain.program")
            unit)]
        [_profile-spans-start : unit
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase
              (profile_state.compiler-profile-state-shared-view profile-state))
            unit)]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [_profile-spans-finish : unit
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (profile_state.compiler-profile-state-shared-view profile-state)
              "retain.spans")
            unit)]
        [out : ResultCompilerDriverBuffer
          (begin
            (compiler_ast_types.ast-node-pool-reader-use!
              (owned_view.compiler-owned-shared-view pools))
            (cfg
              compile-profile
              (compiler-driver-profile-start-phase
                (profile_state.compiler-profile-state-shared-view profile-state)))
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase
                (profile_state.compiler-profile-state-shared-view profile-state)
                "retain.release"))
            (compiler-driver-emit-lowered-buffer-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
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
              profile-state
              backend-state
              typecheck-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (compiler_ast_types.ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriverBuffer.Err diag))]))

(define (compiler-driver-emit-lowered-result-object-image-with-level-mode-entry-and-crt
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverObject
  (match lowered
    [(ResultCompilerDriverLowered.Ok
        program
        spans
        pools
        profile-state
        backend-state
        typecheck-state)
      (let
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              (owned_view.compiler-owned-shared-view pools)
              program)
            program)]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerDriverObject
          (begin
            (compiler_ast_types.ast-node-pool-reader-use!
              (owned_view.compiler-owned-shared-view pools))
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
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
              profile-state
              backend-state
              typecheck-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (compiler_ast_types.ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriverObject.Err diag))]))

(define (compiler-driver-emit-lowered-result-package-runtime-with-level-mode-entry-and-crt
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : compiler_backend.CompilerBackendTarget]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverPackageRuntime
  (match lowered
    [(ResultCompilerDriverLowered.Ok
        program
        spans
        pools
        profile-state
        backend-state
        typecheck-state)
      (let
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              (owned_view.compiler-owned-shared-view pools)
              program)
            program)]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerDriverPackageRuntime
          (begin
            (compiler_ast_types.ast-node-pool-reader-use!
              (owned_view.compiler-owned-shared-view pools))
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-driver-emit-lowered-package-runtime-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
              pools
              input-path
              emit-program
              emit-spans
              target
              mode
              opt-level
              emit-entry
              crt-entry
              profile-state
              backend-state
              typecheck-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (compiler_ast_types.ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriverPackageRuntime.Err diag))]))

(define (compiler-driver-emit-lowered-result-pic-with-level-mode-entry-and-crt
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [mode : compiler_backend.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverPic
  (match lowered
    [(ResultCompilerDriverLowered.Ok
        program
        spans
        pools
        profile-state
        backend-state
        typecheck-state)
      (let
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              (owned_view.compiler-owned-shared-view pools)
              program)
            program)]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerDriverPic
          (begin
            (compiler_ast_types.ast-node-pool-reader-use!
              (owned_view.compiler-owned-shared-view pools))
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-driver-emit-lowered-pic-with-level-mode-entry-and-crt-and-profile-state-and-backend-state
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
              profile-state
              backend-state
              typecheck-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (compiler_ast_types.ast-node-pool-reader-clear!)
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
    (Ok
      compiler_ast_types.AstDeclList
      compiler_ast_types.AstDeclPathList
      compiler_ast_types.AstDeclModuleList
      sym_i64_env.SymI64Env)))

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
              (if (= key compiler_parse_core.compiler-parse-state-marker-id)
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
    [target : compiler_backend.CompilerBackendTarget]) : bool
    (let
      [expected : sym_i64_env.SymI64Env
        (compiler-driver-target-cfgs
          target
          (compiler_parse_core.compiler-cfg-empty))]
      (and
        (compiler-driver-cfg-bindings-match? actual expected)
        (compiler-driver-cfg-bindings-match? expected actual)))))

(cfg
  embedded-stdlib-tlci
  (define (compiler-driver-prelude-surface-configuration
    [cfgs : sym_i64_env.SymI64Env]) : String
    (cond
      [(compiler-driver-cfgs-match-default?
          cfgs
          (compiler_backend.CompilerBackendTarget.Linux))
        "linux-default"]
      [(compiler-driver-cfgs-match-default?
          cfgs
          (compiler_backend.CompilerBackendTarget.Windows))
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
      (string.eq key.package-name "stdlib.prelude")
      (string.eq key.compiler-build outer-build)
      (string.eq key.configuration configuration)
      (> (string.string-length expected-source-hash) 0)
      (string.eq key.source-hash expected-source-hash))))

(cfg
  embedded-stdlib-tlci
  (define (compiler-driver-hydrate-prelude-rodata
    [load-state : compiler_load.CompilerLoadSessionState]
    [outer-build : String]
    [expected-source-hash : String]
    [rodata : (__tl_dyn-array u8)]
    [configuration : String]
    [pools : compiler_ast_types.AstNodePoolContext]) : CompilerDriverPreludeSurface
    (match (tlci.tlci-producer-identity-admit
      outer-build
      (build_identity.compiler-build-git-hash-shared-view))
      [(tlci.TlciProducerIdentityAdmission.ExactMatch)
        (match (compiler_surface_hydrate.compiler-surface-key
          (owned_view.compiler-owned-shared-view rodata))
          [(compiler_surface_hydrate.ResultCompilerSurfaceKey.Missing)
            CompilerDriverPreludeSurface.Missing]
          [(compiler_surface_hydrate.ResultCompilerSurfaceKey.Err _)
            CompilerDriverPreludeSurface.Missing]
          [(compiler_surface_hydrate.ResultCompilerSurfaceKey.Ok key)
            (if (not
              (compiler-driver-prelude-surface-key-valid?
                (owned_view.compiler-owned-shared-view key)
                outer-build
                expected-source-hash
                configuration))
              CompilerDriverPreludeSurface.Missing
              (match (compiler_surface_hydrate.compiler-surface-hydrate
                rodata
                key
                (compiler_load.compiler-load-session-state-structural-session
                  load-state)
                pools)
                [(compiler_surface_hydrate.ResultCompilerSurfaceHydration.Missing)
                  CompilerDriverPreludeSurface.Missing]
                [(compiler_surface_hydrate.ResultCompilerSurfaceHydration.KeyMismatch
                    _)
                  CompilerDriverPreludeSurface.Missing]
                [(compiler_surface_hydrate.ResultCompilerSurfaceHydration.Err _)
                  CompilerDriverPreludeSurface.Missing]
                [(compiler_surface_hydrate.ResultCompilerSurfaceHydration.Ok
                    hydration)
                  (let
                    [ast : surface_ast.SurfaceAstHydration hydration.ast]
                    [facts : compiler_surface_facts.SurfaceTypecheckFacts
                      hydration.facts]
                    (if (compiler_surface_facts.surface-typecheck-facts-publish!
                      facts)
                      (CompilerDriverPreludeSurface.Ok
                        ast.decls
                        ast.paths
                        ast.modules
                        ast.seen)
                      CompilerDriverPreludeSurface.Missing))]))])]
      [_ CompilerDriverPreludeSurface.Missing])))

(cfg
  embedded-stdlib-tlci
  (define (compiler-driver-try-hydrate-runtime-prelude
    [load-state : compiler_load.CompilerLoadSessionState]
    [stdlib-roots : svec.Vec]
    [cfgs : sym_i64_env.SymI64Env]
    [pools : compiler_ast_types.AstNodePoolContext]
    [surface-arena : i64]) : CompilerDriverPreludeSurface
    (let
      [configuration : String
        (compiler-driver-prelude-surface-configuration cfgs)]
      (if (or
        (= surface-arena 0)
        (compiler_load.compiler-load-stdlib-root-configured? stdlib-roots)
        (= (string.string-length configuration) 0))
        CompilerDriverPreludeSurface.Missing
        (in-arena
          (arena.Arena surface-arena)
          (match (embedded_tlci.compiler-embedded-stdlib-tlci-surface)
            [(embedded_tlci.CompilerEmbeddedStdlibTlciSurface.Unavailable _)
              CompilerDriverPreludeSurface.Missing]
            [(embedded_tlci.CompilerEmbeddedStdlibTlciSurface.Ok
                outer-build
                source-hash
                rodata)
              (compiler-driver-hydrate-prelude-rodata
                load-state
                outer-build
                source-hash
                rodata
                configuration
                pools)]))))))

(define (compiler-driver-load-runtime-prelude-cold-and-profile-state
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (begin
    (compiler-driver-profile-note-prelude-source-pipeline! profile-state)
    (match (compiler_load.compiler-load-stdlib-prelude-file-with-roots-cfg
      (compiler_load.compiler-load-runtime-prelude-path-shared-view)
      (sym_i64_env.sym-i64-empty)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      (owned_view.compiler-owned-shared-view cfgs))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok
          runtime-decls
          runtime-paths
          runtime-modules
          runtime-seen)
        (match (compiler_load.compiler-load-core-macro-prelude-with-roots-cfg
          runtime-seen
          stdlib-roots
          cfgs)
          [(compiler_load.ResultCompilerLoadWithPaths.Ok
              macro-decls
              macro-paths
              macro-modules
              macro-seen)
            (compiler_load.ResultCompilerLoadWithPaths.Ok
              (compiler_load.compiler-load-decl-list-append
                runtime-decls
                macro-decls)
              (compiler_load.compiler-load-decl-path-list-append
                runtime-paths
                macro-paths)
              (compiler_load.compiler-load-decl-module-list-append
                runtime-modules
                macro-modules)
              macro-seen)]
          [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
            (compiler_load.ResultCompilerLoadWithPaths.Err diag)])]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (compiler_load.ResultCompilerLoadWithPaths.Err diag)])))

(define (compiler-driver-load-runtime-prelude-cold
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler-driver-load-runtime-prelude-cold-and-profile-state
    stdlib-roots
    cfgs
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-load-runtime-prelude-cache-miss-and-profile-state
  [key : compiler_load.CompilerLoadPreludeCacheKey]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (in-arena
    (arena.Arena compiler_ast_types.node-pool-base-arena)
    (let
      [persistent-key : compiler_load.CompilerLoadPreludeCacheKey
        (compiler_load.compiler-load-prelude-cache-key-copy key)]
      [cold : compiler_load.ResultCompilerLoadWithPaths
        (compiler-driver-load-runtime-prelude-cold-and-profile-state
          stdlib-roots
          cfgs
          profile-state)]
      (begin
        (match (owned_view.compiler-owned-shared-view cold)
          [(compiler_load.ResultCompilerLoadWithPaths.Ok
              decls
              paths
              modules
              seen)
            (compiler-driver-runtime-prelude-cache-store
              persistent-key
              decls
              paths
              modules
              seen)]
          [(compiler_load.ResultCompilerLoadWithPaths.Err _) unit])
        cold))))

(define (compiler-driver-load-runtime-prelude-cache-miss
  [key : compiler_load.CompilerLoadPreludeCacheKey]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler-driver-load-runtime-prelude-cache-miss-and-profile-state
    key
    stdlib-roots
    cfgs
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-load-runtime-prelude-and-profile-state
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (if (compiler_load.compiler-load-session-cache-enabled?)
    (let
      [key : compiler_load.CompilerLoadPreludeCacheKey
        (compiler_load.compiler-load-runtime-prelude-cache-key
          (owned_view.compiler-owned-shared-view stdlib-roots)
          (owned_view.compiler-owned-shared-view cfgs))]
      (match (compiler-driver-runtime-prelude-cache-lookup
        (owned_view.compiler-owned-shared-view key))
        [(CompilerLoadPreludeCacheHit decls paths modules seen)
          (compiler_load.ResultCompilerLoadWithPaths.Ok
            decls
            paths
            modules
            seen)]
        [(CompilerLoadPreludeCacheMiss)
          (compiler-driver-load-runtime-prelude-cache-miss-and-profile-state
            key
            stdlib-roots
            cfgs
            profile-state)]))
    (compiler-driver-load-runtime-prelude-cold-and-profile-state
      stdlib-roots
      cfgs
      profile-state)))

(define (compiler-driver-load-runtime-prelude
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler-driver-load-runtime-prelude-and-profile-state
    stdlib-roots
    cfgs
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-load-file-with-runtime-and-profile-state
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  ;; Prepend the implicit prelude (runtime + core macros), then load the entry.
  (match (compiler-driver-load-runtime-prelude-and-profile-state
    (owned_view.compiler-owned-shared-view stdlib-roots)
    (owned_view.compiler-owned-shared-view cfgs)
    profile-state)
    [(compiler_load.ResultCompilerLoadWithPaths.Ok
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler_load.compiler-load-entry-file-with-paths-and-roots-cfg
        input-path
        prelude-seen
        stdlib-roots
        cfgs)
        [(compiler_load.ResultCompilerLoadWithPaths.Ok
            entry-decls
            entry-paths
            entry-modules
            seen)
          (compiler_load.ResultCompilerLoadWithPaths.Ok
            (compiler_load.compiler-load-decl-list-append
              prelude-decls
              entry-decls)
            (compiler_load.compiler-load-decl-path-list-append
              prelude-paths
              entry-paths)
            (compiler_load.compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
          (compiler_load.ResultCompilerLoadWithPaths.Err diag)])]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (compiler_load.ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-file-with-runtime
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler-driver-load-file-with-runtime-and-profile-state
    input-path
    stdlib-roots
    cfgs
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-load-file-for-pic-image
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : compiler_load.ResultCompilerLoadWithPaths
  (match (compiler_load.compiler-load-core-macro-prelude-with-roots-cfg
    (sym_i64_env.sym-i64-empty)
    (owned_view.compiler-owned-shared-view stdlib-roots)
    (owned_view.compiler-owned-shared-view cfgs))
    [(compiler_load.ResultCompilerLoadWithPaths.Ok
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler_load.compiler-load-entry-file-with-paths-and-roots-cfg
        input-path
        prelude-seen
        stdlib-roots
        cfgs)
        [(compiler_load.ResultCompilerLoadWithPaths.Ok
            entry-decls
            entry-paths
            entry-modules
            seen)
          (compiler_load.ResultCompilerLoadWithPaths.Ok
            (compiler_load.compiler-load-decl-list-append
              prelude-decls
              entry-decls)
            (compiler_load.compiler-load-decl-path-list-append
              prelude-paths
              entry-paths)
            (compiler_load.compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
          (compiler_load.ResultCompilerLoadWithPaths.Err diag)])]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (compiler_load.ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-runtime-prelude-cold-with-pools
  [load-state : compiler_load.CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (begin
    (compiler-driver-profile-note-prelude-source-pipeline! profile-state)
    (match (compiler_load.compiler-load-stdlib-prelude-file-with-roots-cfg-with-pools
      (owned_view.compiler-owned-shared-view load-state)
      (compiler_load.compiler-load-runtime-prelude-path-shared-view)
      (sym_i64_env.sym-i64-empty)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      (owned_view.compiler-owned-shared-view cfgs)
      (owned_view.compiler-owned-shared-view pools))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok
          runtime-decls
          runtime-paths
          runtime-modules
          runtime-seen)
        (match (compiler_load.compiler-load-core-macro-prelude-with-roots-cfg-with-pools
          load-state
          runtime-seen
          stdlib-roots
          cfgs
          pools)
          [(compiler_load.ResultCompilerLoadWithPaths.Ok
              macro-decls
              macro-paths
              macro-modules
              macro-seen)
            (compiler_load.ResultCompilerLoadWithPaths.Ok
              (compiler_load.compiler-load-decl-list-append
                runtime-decls
                macro-decls)
              (compiler_load.compiler-load-decl-path-list-append
                runtime-paths
                macro-paths)
              (compiler_load.compiler-load-decl-module-list-append
                runtime-modules
                macro-modules)
              macro-seen)]
          [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
            (compiler_load.ResultCompilerLoadWithPaths.Err diag)])]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (compiler_load.ResultCompilerLoadWithPaths.Err diag)])))

(define (compiler-driver-load-runtime-prelude-cache-miss-with-state-and-pools
  [load-state : compiler_load.CompilerLoadSessionState]
  [key : compiler_load.CompilerLoadPreludeCacheKey]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (in-arena
    (arena.Arena (compiler_ast_types.ast-node-pool-context-base-arena pools))
    (let
      [persistent-key : compiler_load.CompilerLoadPreludeCacheKey
        (compiler_load.compiler-load-prelude-cache-key-copy key)]
      [cold : compiler_load.ResultCompilerLoadWithPaths
        (compiler-driver-load-runtime-prelude-cold-with-pools
          (owned_view.compiler-owned-shared-view load-state)
          stdlib-roots
          cfgs
          (owned_view.compiler-owned-shared-view pools)
          (profile_state.compiler-profile-state-shared-view profile-state))]
      (begin
        (match (owned_view.compiler-owned-shared-view cold)
          [(compiler_load.ResultCompilerLoadWithPaths.Ok
              decls
              paths
              modules
              seen)
            (compiler-driver-runtime-prelude-cache-store-with-state-and-pools
              load-state
              persistent-key
              decls
              paths
              modules
              seen
              pools)]
          [(compiler_load.ResultCompilerLoadWithPaths.Err _) unit])
        cold))))

(define (compiler-driver-load-runtime-prelude-ordinary-with-state-and-pools
  [load-state : compiler_load.CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (if (compiler_load.compiler-load-session-state-cache-enabled? load-state)
    (let
      [key : compiler_load.CompilerLoadPreludeCacheKey
        (compiler_load.compiler-load-session-state-runtime-prelude-cache-key
          (owned_view.compiler-owned-shared-view load-state)
          (owned_view.compiler-owned-shared-view stdlib-roots)
          (owned_view.compiler-owned-shared-view cfgs))]
      (match (compiler-driver-runtime-prelude-cache-lookup-with-state
        (owned_view.compiler-owned-shared-view load-state)
        (owned_view.compiler-owned-shared-view key))
        [(CompilerLoadPreludeCacheHit decls paths modules seen)
          (compiler_load.ResultCompilerLoadWithPaths.Ok
            decls
            paths
            modules
            seen)]
        [(CompilerLoadPreludeCacheMiss)
          (compiler-driver-load-runtime-prelude-cache-miss-with-state-and-pools
            load-state
            key
            stdlib-roots
            cfgs
            pools
            profile-state)]))
    (compiler-driver-load-runtime-prelude-cold-with-pools
      load-state
      stdlib-roots
      cfgs
      pools
      profile-state)))

(define (compiler-driver-load-runtime-prelude-with-state-pools-and-surface
  [load-state : compiler_load.CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]
  ;; lint-allow: unused-variable -- used by embedded-stdlib-tlci builds.
  [surface-arena : i64]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
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
          (owned_view.compiler-owned-shared-view load-state)
          (owned_view.compiler-owned-shared-view stdlib-roots)
          (owned_view.compiler-owned-shared-view cfgs)
          (owned_view.compiler-owned-shared-view pools)
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
            pools
            profile-state)]
        [(CompilerDriverPreludeSurface.Ok decls paths modules seen)
          (begin
            ;; Hydration bypasses the ordinary stdlib source loader, so record
            ;; the embedded provenance that loader would have attached. Macro
            ;; routing must not depend on an unrelated later import happening
            ;; to resolve core_macros.tl from the embedded payload.
            (compiler_load.compiler-load-session-state-note-embedded-module!
              (owned_view.compiler-owned-shared-view load-state)
              (compiler_load.compiler-load-core-macro-prelude-path-shared-view))
            ;; core_macros imports stdlib.clone for the late typed helper
            ;; splice. Hydration bypasses that import's ordinary source
            ;; provenance hook too, and the late splice runs after the primary
            ;; macro walk, so name the transitive macro owner explicitly.
            (compiler_load.compiler-load-session-state-note-embedded-module!
              (owned_view.compiler-owned-shared-view load-state)
              (compiler_load.compiler-load-clone-prelude-path-shared-view))
            (compiler_load.compiler-load-session-state-note-embedded-module!
              (owned_view.compiler-owned-shared-view load-state)
              (compiler_load.compiler-load-runtime-prelude-path-shared-view))
            (compiler_load.compiler-load-session-state-note-embedded-stdlib-source!
              load-state)
            (compiler-driver-profile-note-prelude-hydration! profile-state)
            (compiler_load.ResultCompilerLoadWithPaths.Ok
              decls
              paths
              modules
              seen))]))
    (compiler-driver-load-runtime-prelude-ordinary-with-state-and-pools
      load-state
      stdlib-roots
      cfgs
      pools
      profile-state)))

(define (compiler-driver-load-runtime-prelude-with-state-and-pools
  [load-state : compiler_load.CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler-driver-load-runtime-prelude-with-state-pools-and-surface
    (owned_view.compiler-owned-shared-view load-state)
    stdlib-roots
    cfgs
    pools
    0
    profile-state))

(define (compiler-driver-load-file-with-runtime-with-state-pools-and-surface
  [load-state : compiler_load.CompilerLoadSessionState]
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]
  [surface-arena : i64]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (let
    [_prelude-begin : unit
      (cfg
        compile-startup-profile
        (startup_profile.compiler-startup-profile-mark-prelude-begin!)
        unit)]
    [prelude : compiler_load.ResultCompilerLoadWithPaths
      (compiler-driver-load-runtime-prelude-with-state-pools-and-surface
        (owned_view.compiler-owned-shared-view load-state)
        (owned_view.compiler-owned-shared-view stdlib-roots)
        (owned_view.compiler-owned-shared-view cfgs)
        (owned_view.compiler-owned-shared-view pools)
        surface-arena
        (profile_state.compiler-profile-state-shared-view profile-state))]
    [_prelude-end : unit
      (cfg
        compile-startup-profile
        (startup_profile.compiler-startup-profile-mark-prelude-end!)
        unit)]
    (match prelude
      [(compiler_load.ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (begin
          (cfg
            compile-startup-profile
            (startup_profile.compiler-startup-profile-mark-user-entry-start!)
            unit)
          (match (compiler_load.compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
            load-state
            input-path
            prelude-seen
            (owned_view.compiler-owned-shared-view stdlib-roots)
            cfgs
            pools)
            [(compiler_load.ResultCompilerLoadWithPaths.Ok
                entry-decls
                entry-paths
                entry-modules
                seen)
              (compiler_load.ResultCompilerLoadWithPaths.Ok
                (compiler_load.compiler-load-decl-list-append
                  prelude-decls
                  entry-decls)
                (compiler_load.compiler-load-decl-path-list-append
                  prelude-paths
                  entry-paths)
                (compiler_load.compiler-load-decl-module-list-append
                  prelude-modules
                  entry-modules)
                seen)]
            [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
              (compiler_load.ResultCompilerLoadWithPaths.Err diag)]))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (compiler_load.ResultCompilerLoadWithPaths.Err diag)])))

(define (compiler-driver-load-source-with-runtime-with-state-and-pools
  [load-state : compiler_load.CompilerLoadSessionState]
  [input-path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (match (compiler-driver-load-runtime-prelude-with-state-and-pools
    (owned_view.compiler-owned-shared-view load-state)
    (owned_view.compiler-owned-shared-view stdlib-roots)
    (owned_view.compiler-owned-shared-view cfgs)
    (owned_view.compiler-owned-shared-view pools)
    (profile_state.compiler-profile-state-shared-view profile-state))
    [(compiler_load.ResultCompilerLoadWithPaths.Ok
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler_load.compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
        load-state
        input-path
        source
        prelude-seen
        (owned_view.compiler-owned-shared-view stdlib-roots)
        compiler_ast_types.AstMaybeModuleName.No
        cfgs
        pools)
        [(compiler_load.ResultCompilerLoadWithPaths.Ok
            entry-decls
            entry-paths
            entry-modules
            seen)
          (compiler_load.ResultCompilerLoadWithPaths.Ok
            (compiler_load.compiler-load-decl-list-append
              prelude-decls
              entry-decls)
            (compiler_load.compiler-load-decl-path-list-append
              prelude-paths
              entry-paths)
            (compiler_load.compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
          (compiler_load.ResultCompilerLoadWithPaths.Err diag)])]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (compiler_load.ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-source-with-runtime-with-pools
  [input-path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler-driver-load-source-with-runtime-with-state-and-pools
    (compiler_load.compiler-load-active-session-state-shared-view)
    input-path
    source
    stdlib-roots
    cfgs
    pools
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-load-file-for-pic-image-with-pools
  [load-state : compiler_load.CompilerLoadSessionState]
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]) : compiler_load.ResultCompilerLoadWithPaths
  (match (compiler_load.compiler-load-core-macro-prelude-with-roots-cfg-with-pools
    (owned_view.compiler-owned-shared-view load-state)
    (sym_i64_env.sym-i64-empty)
    (owned_view.compiler-owned-shared-view stdlib-roots)
    (owned_view.compiler-owned-shared-view cfgs)
    (owned_view.compiler-owned-shared-view pools))
    [(compiler_load.ResultCompilerLoadWithPaths.Ok
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (compiler_load.compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
        load-state
        input-path
        prelude-seen
        stdlib-roots
        cfgs
        pools)
        [(compiler_load.ResultCompilerLoadWithPaths.Ok
            entry-decls
            entry-paths
            entry-modules
            seen)
          (compiler_load.ResultCompilerLoadWithPaths.Ok
            (compiler_load.compiler-load-decl-list-append
              prelude-decls
              entry-decls)
            (compiler_load.compiler-load-decl-path-list-append
              prelude-paths
              entry-paths)
            (compiler_load.compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
          (compiler_load.ResultCompilerLoadWithPaths.Err diag)])]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (compiler_load.ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-load-and-lower-escaping-and-profile-state
  [input-path : String]
  [target : compiler_backend.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverLowered
  (match (compiler-driver-load-file-with-runtime
    (owned_view.compiler-owned-shared-view input-path)
    (owned_view.compiler-owned-shared-view stdlib-roots)
    (owned_view.compiler-owned-shared-view cfgs))
    [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths modules _)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase
            (profile_state.compiler-profile-state-shared-view profile-state)
            "load"))
        (cfg
          compile-profile
          (compiler-driver-profile-start-phase
            (profile_state.compiler-profile-state-shared-view profile-state)))
        (match (compiler_lower.lower-compiler-program-with-decl-paths-mode-cache
          (owned_view.compiler-owned-shared-view input-path)
          (compiler_ast_types.ast-program decls)
          (compiler_ast_types.ast-decl-path-list-with-modules paths modules)
          (compiler-driver-lower-mode-for-target target mode)
          (owned_view.compiler-owned-shared-view stdlib-roots)
          (compiler_load.compiler-load-prelude-cache-key
            "typecheck-prefix-lower"
            stdlib-roots
            cfgs))
          [(compiler_lower.ResultCompilerLower.Ok program spans)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase
                  (profile_state.compiler-profile-state-shared-view
                    profile-state)
                  "lower"))
              (if (compiler_ast_types.ast-node-pool-reader-type-exhausted?)
                (ResultCompilerDriverLowered.Err
                  (box
                    (compiler-driver-ty-node-pool-exhausted-diagnostic
                      input-path)))
                (compiler-driver-lowered-from-active-pools-and-profile-state
                  program
                  spans
                  profile-state)))]
          [(compiler_lower.ResultCompilerLower.Err diag)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase
                  (profile_state.compiler-profile-state-shared-view
                    profile-state)
                  "lower"))
              (ResultCompilerDriverLowered.Err diag))]))]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase
            (profile_state.compiler-profile-state-shared-view profile-state)
            "load"))
        (ResultCompilerDriverLowered.Err diag))]))

(define (compiler-driver-load-and-lower-escaping
  [input-path : String]
  [target : compiler_backend.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : compiler_backend.CompilerBackendMode]
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
  [target : compiler_backend.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverLowered
  (match (compiler-driver-load-file-for-pic-image
    (owned_view.compiler-owned-shared-view input-path)
    (owned_view.compiler-owned-shared-view stdlib-roots)
    (owned_view.compiler-owned-shared-view cfgs))
    [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths modules _)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase
            (profile_state.compiler-profile-state-shared-view profile-state)
            "load"))
        (cfg
          compile-profile
          (compiler-driver-profile-start-phase
            (profile_state.compiler-profile-state-shared-view profile-state)))
        (match (compiler_lower.lower-compiler-program-with-decl-paths-mode-cache
          (owned_view.compiler-owned-shared-view input-path)
          (compiler_ast_types.ast-program decls)
          (compiler_ast_types.ast-decl-path-list-with-modules paths modules)
          (compiler-driver-lower-mode-for-target target mode)
          (owned_view.compiler-owned-shared-view stdlib-roots)
          (compiler_load.compiler-load-prelude-cache-key
            "typecheck-prefix-lower"
            stdlib-roots
            cfgs))
          [(compiler_lower.ResultCompilerLower.Ok program spans)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase
                  (profile_state.compiler-profile-state-shared-view
                    profile-state)
                  "lower"))
              (if (compiler_ast_types.ast-node-pool-reader-type-exhausted?)
                (ResultCompilerDriverLowered.Err
                  (box
                    (compiler-driver-ty-node-pool-exhausted-diagnostic
                      input-path)))
                (compiler-driver-lowered-from-active-pools-and-profile-state
                  program
                  spans
                  profile-state)))]
          [(compiler_lower.ResultCompilerLower.Err diag)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase
                  (profile_state.compiler-profile-state-shared-view
                    profile-state)
                  "lower"))
              (ResultCompilerDriverLowered.Err diag))]))]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase
            (profile_state.compiler-profile-state-shared-view profile-state)
            "load"))
        (ResultCompilerDriverLowered.Err diag))]))

(define (compiler-driver-load-and-lower-pic-image
  [input-path : String]
  [target : compiler_backend.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : compiler_backend.CompilerBackendMode]
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
  [target : compiler_backend.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [retire-after-lower? : bool]) : ResultCompilerDriverLowered
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler-driver-state-pool-context
        (owned_view.compiler-owned-shared-view state))]
    [release-source-pools? : bool
      (compiler-driver-state-can-release-checked-lower-source-pools?
        (owned_view.compiler-owned-shared-view state))]
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
    [_install-interns : unit
      (compiler-driver-state-install-interns!
        (owned_view.compiler-owned-shared-view state))]
    [parser-state : compiler_parse_core.CompilerParseState
      (owned_view.compiler-owned-shared-view state.parser-state)]
    [parse-cfgs : sym_i64_env.SymI64Env
      (compiler_parse_core.compiler-parse-state-cfgs
        (owned_view.compiler-owned-shared-view parser-state)
        (owned_view.compiler-owned-shared-view cfgs))]
    (match (compiler-driver-load-file-with-runtime-with-state-pools-and-surface
      (owned_view.compiler-owned-shared-view state.load-session)
      (owned_view.compiler-owned-shared-view input-path)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      (owned_view.compiler-owned-shared-view parse-cfgs)
      (owned_view.compiler-owned-shared-view pools)
      (compiler-driver-state-surface-arena
        (owned_view.compiler-owned-shared-view state))
      (compiler-driver-state-profile
        (owned_view.compiler-owned-shared-view state)))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths modules _)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (compiler-driver-state-profile
                (owned_view.compiler-owned-shared-view state))
              "load"))
          (cfg
            compile-profile
            (compiler-driver-profile-prelude-counters
              (compiler-driver-state-profile
                (owned_view.compiler-owned-shared-view state))))
          (compiler-driver-allocation-profile-snapshot-for-job!
            (compiler-driver-state-typecheck
              (owned_view.compiler-owned-shared-view state))
            "load")
          (compiler-driver-allocation-profile-pool-storage-snapshot!
            "source-load"
            (owned_view.compiler-owned-shared-view pools))
          (cfg
            compile-profile
            (compiler_lower.compiler-lower-profile-pools
              "source_load"
              (owned_view.compiler-owned-shared-view pools))
            unit)
          ;; Load has returned its declaration list, so the lexer token buffer
          ;; and the unspanned reader pool are dead scan scratch that would
          ;; otherwise sit on the retain.program/retain.release peak for the
          ;; rest of the process. Retire them here, on the same uncached
          ;; single-entry gate the source-arena retirement uses, so a session
          ;; that reuses loader state across jobs keeps its warm capacity.
          (if route-source-allocations?
            (compiler_load.compiler-load-release-frontend-scan-arenas!)
            unit)
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase
              (compiler-driver-state-profile
                (owned_view.compiler-owned-shared-view state))))
          ;; Parsing initialized builtin IDs for this state's active intern
          ;; table. Preserve that snapshot instead of reinstalling the stale
          ;; pre-parse builtin state; only lowerer arenas need restoration here.
          (compiler-driver-state-capture-active-builtins!
            (owned_view.compiler-owned-shared-view state))
          (compiler-driver-state-install-lower-arenas!
            (owned_view.compiler-owned-shared-view state))
          (compiler-driver-state-install-pools!
            (owned_view.compiler-owned-shared-view state))
          (let
            [_capture-source-names : unit
              (compiler-driver-state-capture-active-interns!
                (owned_view.compiler-owned-shared-view state))]
            [source-names : ci.InternSourceNameSessionHandle
              (compiler-driver-state-entry-source-name-session
                (owned_view.compiler-owned-shared-view state))]
            [dest-pools : compiler_ast_types.AstNodePoolContext
              (if release-source-pools?
                (compiler-driver-state-new-checked-lower-pools)
                pools)]
            [_profile-checked-storage : unit
              (begin
                (compiler-driver-allocation-profile-pool-storage-snapshot!
                  "checked-pool"
                  (owned_view.compiler-owned-shared-view dest-pools))
                (cfg
                  compile-profile
                  (compiler_lower.compiler-lower-profile-pools
                    "checked_pool"
                    (owned_view.compiler-owned-shared-view dest-pools))
                  unit))]
            [entry-arena : i64 (arena.tl_arena_current)]
            ;; Release the source pools from the newest segment of their arena
            ;; chain, not the make() root handle: the chain is reachable only from
            ;; its head, so destroying the root leaks every overflow segment (the
            ;; whole-program parsed AST), which accumulates across batch entries.
            [source-pools-arena : i64
              (compiler_ast_types.ast-node-pool-context-base-arena pools)]
            [_clear-source-floors : unit
              (if release-source-pools?
                (compiler_load.compiler-load-session-state-floors-set!
                  (owned_view.compiler-owned-shared-view state.load-session)
                  0
                  0
                  0)
                unit)]
            [_arm-release : unit
              (if release-source-pools?
                (compiler_lower.compiler-lower-checked-dest-pools-use!
                  (compiler-driver-state-owned-lower-state
                    (owned_view.compiler-owned-shared-view state))
                  (owned_view.compiler-owned-shared-view dest-pools)
                  source-pools-arena
                  (compiler_ast_types.ast-node-pool-context-expr-storage-arena
                    pools)
                  (compiler_ast_types.ast-node-pool-context-type-storage-arena
                    pools)
                  (if route-source-allocations?
                    frontend-arena
                    0))
                (compiler_lower.compiler-lower-checked-dest-pools-clear!
                  (compiler-driver-state-owned-lower-state
                    (owned_view.compiler-owned-shared-view state))))]
            [lowered-raw : compiler_lower.ResultCompilerLower
              (compiler_lower.lower-compiler-program-with-decl-paths-mode-cache-and-pools-and-source-names-and-load-state-and-intern-state
                (compiler-driver-state-owned-lower-state
                  (owned_view.compiler-owned-shared-view state))
                (owned_view.compiler-owned-shared-view state.load-session)
                (owned_view.compiler-owned-shared-view
                  state.typecheck-prefix-cache)
                (owned_view.compiler-owned-shared-view state.typecheck-state)
                (owned_view.compiler-owned-shared-view input-path)
                (compiler_ast_types.ast-program decls)
                (compiler_ast_types.ast-decl-path-list-with-modules
                  paths
                  modules)
                (compiler-driver-lower-mode-for-target target mode)
                (owned_view.compiler-owned-shared-view stdlib-roots)
                (compiler_load.compiler-load-prelude-cache-key
                  "typecheck-prefix-lower"
                  (owned_view.compiler-owned-shared-view stdlib-roots)
                  (owned_view.compiler-owned-shared-view cfgs))
                (owned_view.compiler-owned-shared-view pools)
                (owned_view.compiler-owned-shared-view source-names)
                (compiler-driver-state-owned-interns
                  (owned_view.compiler-owned-shared-view state))
                (compiler-driver-state-owned-builtins
                  (owned_view.compiler-owned-shared-view state)))]
            [lowered : compiler_lower.ResultCompilerLower
              (match (owned_view.compiler-owned-shared-view lowered-raw)
                [(compiler_lower.ResultCompilerLower.Ok program spans)
                  (compiler_lower.ResultCompilerLower.Ok program spans)]
                [(compiler_lower.ResultCompilerLower.Err diag)
                  (compiler_lower.ResultCompilerLower.Err
                    (compiler-driver-diagnostic-copy-to-state-surface
                      (owned_view.compiler-owned-shared-view state)
                      diag))])]
            [dest-committed? : bool
              (compiler_lower.compiler-lower-checked-dest-pools-committed?
                (compiler-driver-state-owned-lower-state
                  (owned_view.compiler-owned-shared-view state)))]
            [frontend-released? : bool
              (compiler_lower.compiler-lower-checked-frontend-released?
                (compiler-driver-state-owned-lower-state
                  (owned_view.compiler-owned-shared-view state)))]
            [result-pools : compiler_ast_types.AstNodePoolContext
              (if dest-committed?
                (compiler_lower.compiler-lower-checked-dest-pools-current
                  (compiler-driver-state-owned-lower-state
                    (owned_view.compiler-owned-shared-view state)))
                pools)]
            [_adopt-dest : unit
              (if dest-committed?
                (compiler-driver-state-adopt-pools!
                  (owned_view.compiler-owned-shared-view state)
                  (owned_view.compiler-owned-shared-view result-pools))
                unit)]
            [_destroy-unused-dest : unit
              (if (and release-source-pools? (not dest-committed?))
                (begin
                  (compiler_lower.compiler-lower-checked-dest-pools-abort-uncommitted!
                    (compiler-driver-state-owned-lower-state
                      (owned_view.compiler-owned-shared-view state)))
                  (compiler-driver-state-destroy-uncommitted-pools! dest-pools))
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
                        (compiler_ast_types.ast-node-pool-context-base-arena
                          result-pools)
                        entry-arena))))
                unit)]
            [_clear-release : unit
              (compiler_lower.compiler-lower-checked-dest-pools-clear!
                (compiler-driver-state-owned-lower-state
                  (owned_view.compiler-owned-shared-view state)))]
            (match lowered
              [(compiler_lower.ResultCompilerLower.Ok program spans)
                (begin
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase
                      (compiler-driver-state-profile
                        (owned_view.compiler-owned-shared-view state))
                      "lower"))
                  (compiler-driver-allocation-profile-pool-storage-snapshot!
                    "macro-detach"
                    (owned_view.compiler-owned-shared-view result-pools))
                  (cfg
                    compile-profile
                    (compiler_lower.compiler-lower-profile-pools
                      "macro_detach"
                      (owned_view.compiler-owned-shared-view result-pools))
                    unit)
                  ;; Typecheck re-enters the loader for macro-materialized
                  ;; imports and surface-summary refreshes, so both scan owners
                  ;; can have regrown a fresh arena since the load boundary.
                  ;; Retire them again now that no frontend work remains: the
                  ;; optimizer, backend, and writer never lex or read.
                  (if route-source-allocations?
                    (compiler_load.compiler-load-release-frontend-scan-arenas!)
                    unit)
                  (compiler-driver-state-prefix-cache-allocation-profile-snapshot!
                    (owned_view.compiler-owned-shared-view state)
                    "lower")
                  (compiler-driver-allocation-profile-snapshot-for-job!
                    (compiler-driver-state-typecheck
                      (owned_view.compiler-owned-shared-view state))
                    "lower")
                  (if (compiler_ast_types.ast-node-pool-context-type-exhausted?
                    pools)
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
                      (compiler-driver-lowered-from-pools-and-profile-state-and-backend-state
                        program
                        spans
                        result-pools
                        (compiler-driver-state-profile
                          (owned_view.compiler-owned-shared-view state))
                        (compiler-driver-state-backend
                          (owned_view.compiler-owned-shared-view state))
                        (compiler-driver-state-typecheck state)))))]
              [(compiler_lower.ResultCompilerLower.Err diag)
                (begin
                  ;; A lower-phase failure can leave the state's checked pool
                  ;; storage already retired by the checked-lower choreography
                  ;; (the rollover/commit paths retire source storage during
                  ;; macro expansion). Re-own a fresh, live pool context so the
                  ;; batch/file release path never retires that dead storage
                  ;; again. Refs #5448.
                  (if release-source-pools?
                    (compiler-driver-state-adopt-pools!
                      (owned_view.compiler-owned-shared-view state)
                      (compiler-driver-state-new-checked-lower-pools))
                    unit)
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase
                      (compiler-driver-state-profile
                        (owned_view.compiler-owned-shared-view state))
                      "lower"))
                  (compiler-driver-state-prefix-cache-allocation-profile-snapshot!
                    (owned_view.compiler-owned-shared-view state)
                    "lower")
                  (compiler-driver-allocation-profile-snapshot-for-job!
                    (compiler-driver-state-typecheck
                      (owned_view.compiler-owned-shared-view state))
                    "lower")
                  (ResultCompilerDriverLowered.Err diag))])))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (compiler-driver-state-profile
                (owned_view.compiler-owned-shared-view state))
              "load"))
          (compiler-driver-allocation-profile-snapshot-for-job!
            (compiler-driver-state-typecheck state)
            "load")
          (ResultCompilerDriverLowered.Err diag))])))

(define (compiler-driver-load-and-lower-pic-image-with-state-and-retirement
  [state : CompilerDriverState]
  [input-path : String]
  [target : compiler_backend.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [retire-after-lower? : bool]) : ResultCompilerDriverLowered
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler-driver-state-pool-context
        (owned_view.compiler-owned-shared-view state))]
    [_install-interns : unit
      (compiler-driver-state-install-interns!
        (owned_view.compiler-owned-shared-view state))]
    [parser-state : compiler_parse_core.CompilerParseState
      (owned_view.compiler-owned-shared-view state.parser-state)]
    [parse-cfgs : sym_i64_env.SymI64Env
      (compiler_parse_core.compiler-parse-state-cfgs
        (owned_view.compiler-owned-shared-view parser-state)
        (owned_view.compiler-owned-shared-view cfgs))]
    (match (compiler-driver-load-file-for-pic-image-with-pools
      (owned_view.compiler-owned-shared-view state.load-session)
      (owned_view.compiler-owned-shared-view input-path)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      (owned_view.compiler-owned-shared-view parse-cfgs)
      (owned_view.compiler-owned-shared-view pools))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths modules _)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (compiler-driver-state-profile
                (owned_view.compiler-owned-shared-view state))
              "load"))
          (compiler-driver-allocation-profile-pool-storage-snapshot!
            "source-load"
            (owned_view.compiler-owned-shared-view pools))
          (cfg
            compile-profile
            (compiler_lower.compiler-lower-profile-pools
              "source_load"
              (owned_view.compiler-owned-shared-view pools))
            unit)
          ;; Same frontend scan-scratch retirement as the escaping path above,
          ;; on the same uncached single-entry gate.
          (if (and
            retire-after-lower?
            (compiler-driver-state-can-release-checked-lower-source-pools?
              (owned_view.compiler-owned-shared-view state)))
            (compiler_load.compiler-load-release-frontend-scan-arenas!)
            unit)
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase
              (compiler-driver-state-profile
                (owned_view.compiler-owned-shared-view state))))
          (compiler-driver-state-capture-active-builtins!
            (owned_view.compiler-owned-shared-view state))
          (compiler-driver-state-install-lower-arenas!
            (owned_view.compiler-owned-shared-view state))
          (compiler-driver-state-install-pools!
            (owned_view.compiler-owned-shared-view state))
          (let
            [_capture-source-names : unit
              (compiler-driver-state-capture-active-interns!
                (owned_view.compiler-owned-shared-view state))]
            [intern-state : ci.InternCompatState
              (compiler-driver-state-owned-interns
                (owned_view.compiler-owned-shared-view state))]
            [source-names : ci.InternSourceNameSessionHandle
              (ci.intern-source-name-session-handle
                (ci.intern-source-name-session-from-state intern-state))]
            [release-source-pools? : bool
              (compiler-driver-state-can-release-checked-lower-source-pools?
                (owned_view.compiler-owned-shared-view state))]
            [dest-pools : compiler_ast_types.AstNodePoolContext
              (if release-source-pools?
                (compiler-driver-state-new-checked-lower-pools)
                pools)]
            [_profile-checked-storage : unit
              (begin
                (compiler-driver-allocation-profile-pool-storage-snapshot!
                  "checked-pool"
                  (owned_view.compiler-owned-shared-view dest-pools))
                (cfg
                  compile-profile
                  (compiler_lower.compiler-lower-profile-pools
                    "checked_pool"
                    (owned_view.compiler-owned-shared-view dest-pools))
                  unit))]
            [entry-arena : i64 (arena.tl_arena_current)]
            ;; Release the source pools from the newest segment of their arena
            ;; chain, not the make() root handle: the chain is reachable only from
            ;; its head, so destroying the root leaks every overflow segment (the
            ;; whole-program parsed AST), which accumulates across batch entries.
            [source-pools-arena : i64
              (compiler_ast_types.ast-node-pool-context-base-arena pools)]
            [_clear-source-floors : unit
              (if release-source-pools?
                (compiler_load.compiler-load-session-state-floors-set!
                  (owned_view.compiler-owned-shared-view state.load-session)
                  0
                  0
                  0)
                unit)]
            [_arm-release : unit
              (if release-source-pools?
                (compiler_lower.compiler-lower-checked-dest-pools-use!
                  (compiler-driver-state-owned-lower-state
                    (owned_view.compiler-owned-shared-view state))
                  (owned_view.compiler-owned-shared-view dest-pools)
                  source-pools-arena
                  (compiler_ast_types.ast-node-pool-context-expr-storage-arena
                    pools)
                  (compiler_ast_types.ast-node-pool-context-type-storage-arena
                    pools)
                  0)
                (compiler_lower.compiler-lower-checked-dest-pools-clear!
                  (compiler-driver-state-owned-lower-state
                    (owned_view.compiler-owned-shared-view state))))]
            [lowered-raw : compiler_lower.ResultCompilerLower
              (compiler_lower.lower-compiler-program-with-decl-paths-mode-cache-and-pools-and-source-names-and-load-state-and-intern-state
                (compiler-driver-state-owned-lower-state
                  (owned_view.compiler-owned-shared-view state))
                (owned_view.compiler-owned-shared-view state.load-session)
                (owned_view.compiler-owned-shared-view
                  state.typecheck-prefix-cache)
                (owned_view.compiler-owned-shared-view state.typecheck-state)
                (owned_view.compiler-owned-shared-view input-path)
                (compiler_ast_types.ast-program decls)
                (compiler_ast_types.ast-decl-path-list-with-modules
                  paths
                  modules)
                (compiler-driver-lower-mode-for-target target mode)
                (owned_view.compiler-owned-shared-view stdlib-roots)
                (compiler_load.compiler-load-prelude-cache-key
                  "typecheck-prefix-lower"
                  (owned_view.compiler-owned-shared-view stdlib-roots)
                  (owned_view.compiler-owned-shared-view cfgs))
                (owned_view.compiler-owned-shared-view pools)
                (owned_view.compiler-owned-shared-view source-names)
                (compiler-driver-state-owned-interns
                  (owned_view.compiler-owned-shared-view state))
                (compiler-driver-state-owned-builtins
                  (owned_view.compiler-owned-shared-view state)))]
            [lowered : compiler_lower.ResultCompilerLower
              (match (owned_view.compiler-owned-shared-view lowered-raw)
                [(compiler_lower.ResultCompilerLower.Ok program spans)
                  (compiler_lower.ResultCompilerLower.Ok program spans)]
                [(compiler_lower.ResultCompilerLower.Err diag)
                  (compiler_lower.ResultCompilerLower.Err
                    (compiler-driver-diagnostic-copy-to-state-surface
                      (owned_view.compiler-owned-shared-view state)
                      diag))])]
            [dest-committed? : bool
              (compiler_lower.compiler-lower-checked-dest-pools-committed?
                (compiler-driver-state-owned-lower-state
                  (owned_view.compiler-owned-shared-view state)))]
            [result-pools : compiler_ast_types.AstNodePoolContext
              (if dest-committed?
                (compiler_lower.compiler-lower-checked-dest-pools-current
                  (compiler-driver-state-owned-lower-state
                    (owned_view.compiler-owned-shared-view state)))
                pools)]
            [_adopt-dest : unit
              (if dest-committed?
                (compiler-driver-state-adopt-pools!
                  (owned_view.compiler-owned-shared-view state)
                  (owned_view.compiler-owned-shared-view result-pools))
                unit)]
            [_destroy-unused-dest : unit
              (if (and release-source-pools? (not dest-committed?))
                (begin
                  (compiler_lower.compiler-lower-checked-dest-pools-abort-uncommitted!
                    (compiler-driver-state-owned-lower-state
                      (owned_view.compiler-owned-shared-view state)))
                  (compiler-driver-state-destroy-uncommitted-pools! dest-pools))
                unit)]
            [_restore-entry-arena : unit
              (if release-source-pools?
                (unsafe
                  (arena.tl_arena_set
                    (if (and dest-committed? (= entry-arena source-pools-arena))
                      (compiler_ast_types.ast-node-pool-context-base-arena
                        result-pools)
                      entry-arena)))
                unit)]
            [_clear-release : unit
              (compiler_lower.compiler-lower-checked-dest-pools-clear!
                (compiler-driver-state-owned-lower-state
                  (owned_view.compiler-owned-shared-view state)))]
            (match lowered
              [(compiler_lower.ResultCompilerLower.Ok program spans)
                (begin
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase
                      (compiler-driver-state-profile
                        (owned_view.compiler-owned-shared-view state))
                      "lower"))
                  (compiler-driver-allocation-profile-pool-storage-snapshot!
                    "macro-detach"
                    (owned_view.compiler-owned-shared-view result-pools))
                  (cfg
                    compile-profile
                    (compiler_lower.compiler-lower-profile-pools
                      "macro_detach"
                      (owned_view.compiler-owned-shared-view result-pools))
                    unit)
                  ;; Same post-lower retirement as the escaping path above.
                  (if (and retire-after-lower? release-source-pools?)
                    (compiler_load.compiler-load-release-frontend-scan-arenas!)
                    unit)
                  (if (compiler_ast_types.ast-node-pool-context-type-exhausted?
                    pools)
                    (ResultCompilerDriverLowered.Err
                      (box
                        (compiler-driver-ty-node-pool-exhausted-diagnostic
                          input-path)))
                    (if (and dest-committed? retire-after-lower?)
                      (compiler-driver-state-retain-lowered-types!
                        (owned_view.compiler-owned-shared-view state)
                        (owned_view.compiler-owned-shared-view program)
                        (owned_view.compiler-owned-shared-view spans)
                        (owned_view.compiler-owned-shared-view result-pools))
                      (compiler-driver-lowered-from-pools-and-profile-state-and-backend-state
                        program
                        spans
                        result-pools
                        (compiler-driver-state-profile
                          (owned_view.compiler-owned-shared-view state))
                        (compiler-driver-state-backend
                          (owned_view.compiler-owned-shared-view state))
                        (compiler-driver-state-typecheck
                          (owned_view.compiler-owned-shared-view state))))))]
              [(compiler_lower.ResultCompilerLower.Err diag)
                (begin
                  ;; See the matching note in
                  ;; compiler-driver-load-and-lower-escaping-with-state-and-retirement:
                  ;; a lower-phase failure can leave checked pool storage
                  ;; already retired; re-own a live context before release.
                  ;; Refs #5448.
                  (if release-source-pools?
                    (compiler-driver-state-adopt-pools!
                      (owned_view.compiler-owned-shared-view state)
                      (compiler-driver-state-new-checked-lower-pools))
                    unit)
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase
                      (compiler-driver-state-profile
                        (owned_view.compiler-owned-shared-view state))
                      "lower"))
                  (ResultCompilerDriverLowered.Err diag))])))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (compiler-driver-state-profile
                (owned_view.compiler-owned-shared-view state))
              "load"))
          (ResultCompilerDriverLowered.Err diag))])))

(define (compiler-driver-load-and-lower-pic-image-with-state
  [state : CompilerDriverState]
  [input-path : String]
  [target : compiler_backend.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : compiler_backend.CompilerBackendMode]
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
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [crt-entry : bool]) : ResultCompilerDriver
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (cfg
        compile-profile
        (compiler-driver-profile-start-total
          (profile_state.compiler-profile-state-shared-view profile-state)))
      ;; The lowering provenance side table is remapped after
      ;; optimization so backend diagnostics report surviving instruction
      ;; locations when a rewrite can preserve them.
      (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
        (owned_view.compiler-owned-shared-view input-path)
        (compiler-driver-load-and-lower-escaping-and-profile-state
          (owned_view.compiler-owned-shared-view input-path)
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
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverBuffer
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (cfg
        compile-profile
        (compiler-driver-profile-start-total
          (profile_state.compiler-profile-state-shared-view profile-state)))
      (compiler-driver-emit-lowered-result-buffer-with-level-mode-and-entry
        (owned_view.compiler-owned-shared-view input-path)
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
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [crt-entry : bool]) : ResultCompilerDriverObject
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (cfg
        compile-profile
        (compiler-driver-profile-start-total
          (profile_state.compiler-profile-state-shared-view profile-state)))
      (compiler-driver-emit-lowered-result-object-image-with-level-mode-entry-and-crt
        (owned_view.compiler-owned-shared-view input-path)
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
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverPic
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (cfg
        compile-profile
        (compiler-driver-profile-start-total
          (profile_state.compiler-profile-state-shared-view profile-state)))
      (compiler-driver-emit-lowered-result-pic-with-level-mode-entry-and-crt
        (owned_view.compiler-owned-shared-view input-path)
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
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverBuffer
  (begin
    (cfg
      compile-profile
      (compiler-driver-profile-start-total
        (compiler-driver-state-profile
          (owned_view.compiler-owned-shared-view state))))
    (let
      [lowered : ResultCompilerDriverLowered
        (compiler-driver-load-and-lower-escaping-with-state-and-retirement
          (owned_view.compiler-owned-shared-view state)
          (owned_view.compiler-owned-shared-view input-path)
          target
          stdlib-roots
          mode
          (compiler-driver-state-target-cfgs
            (owned_view.compiler-owned-shared-view state)
            target
            cfgs)
          (>= opt-level 1))]
      ;; No builtin reinstall here: this state's parse already derived the
      ;; installed table, and nothing between parse and emission invalidates
      ;; it. Builtin id values are spelling-derived and identical across
      ;; states, so the backend reads valid ids whichever job parsed last.
      (compiler-driver-emit-lowered-result-buffer-with-level-mode-and-entry
        input-path
        lowered
        target
        has-target
        mode
        opt-level
        true))))

(define (compiler-driver-state-emit-file-pic-with-target-roots-level-mode-and-cfg
  [state : CompilerDriverState]
  [input-path : String]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverPic
  (begin
    (cfg
      compile-profile
      (compiler-driver-profile-start-total
        (compiler-driver-state-profile
          (owned_view.compiler-owned-shared-view state))))
    (let
      [lowered : ResultCompilerDriverLowered
        (compiler-driver-load-and-lower-pic-image-with-state-and-retirement
          (owned_view.compiler-owned-shared-view state)
          (owned_view.compiler-owned-shared-view input-path)
          target
          stdlib-roots
          mode
          (compiler-driver-state-target-cfgs
            (owned_view.compiler-owned-shared-view state)
            target
            cfgs)
          (>= opt-level 1))]
      ;; No builtin reinstall here; see the normal emit wrapper above.
      (compiler-driver-emit-lowered-result-pic-with-level-mode-entry-and-crt
        input-path
        lowered
        target
        has-target
        mode
        opt-level
        false
        false))))

(define (compiler-driver-emit-package-loaded
  [input-path : String]
  [package-name : String]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : compiler_ast_types.AstDeclList]
  [paths : compiler_ast_types.AstDeclPathList]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
    (owned_view.compiler-owned-shared-view input-path)
    (compiler-driver-lower-package-loaded
      input-path
      package-name
      target
      mode
      decls
      paths)
    target
    has-target
    mode
    opt-level
    emit-entry
    crt-entry))

(define (compiler-driver-lower-package-loaded
  [input-path : String]
  [package-name : String]
  [target : compiler_backend.CompilerBackendTarget]
  [mode : compiler_backend.CompilerBackendMode]
  [decls : compiler_ast_types.AstDeclList]
  [paths : compiler_ast_types.AstDeclPathList]) : ResultCompilerDriverLowered
  (match (compiler_lower.lower-compiler-program-with-decl-paths-mode-and-package
    input-path
    (compiler_ast_types.ast-program decls)
    paths
    (compiler-driver-lower-mode-for-target target mode)
    package-name)
    [(compiler_lower.ResultCompilerLower.Ok program spans)
      (compiler-driver-lowered-from-active-pools program spans)]
    [(compiler_lower.ResultCompilerLower.Err diag)
      (ResultCompilerDriverLowered.Err diag)]))

(define (compiler-driver-emit-package-loaded-runtime
  [input-path : String]
  [package-name : String]
  [target : compiler_backend.CompilerBackendTarget]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [emit-entry : bool]
  [crt-entry : bool]
  [decls : compiler_ast_types.AstDeclList]
  [paths : compiler_ast_types.AstDeclPathList]) : ResultCompilerDriverPackageRuntime
  (compiler-driver-emit-lowered-result-package-runtime-with-level-mode-entry-and-crt
    (owned_view.compiler-owned-shared-view input-path)
    (compiler-driver-lower-package-loaded
      input-path
      package-name
      target
      mode
      decls
      paths)
    target
    mode
    opt-level
    emit-entry
    crt-entry))

(define (compiler-driver-load-package-file-with-runtime-cfg
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler_load.compiler-load-package-file-with-runtime-cfg
    input-path
    stdlib-roots
    (owned_view.compiler-owned-shared-view manifest-dir)
    deps
    emit-entry
    cfgs))

(define (compiler-driver-load-package-file-with-runtime
  [input-path : String]
  [target : compiler_backend.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler-driver-load-package-file-with-runtime-cfg
    input-path
    stdlib-roots
    (owned_view.compiler-owned-shared-view manifest-dir)
    deps
    emit-entry
    (compiler-driver-target-cfgs
      target
      (compiler_parse_core.compiler-cfg-empty))))

(define (compiler-driver-load-package-file-with-runtime-owned-cfg
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [package-owner : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]) : compiler_load.ResultCompilerLoadWithPaths
  (match (compiler-driver-load-package-file-with-runtime-cfg
    (owned_view.compiler-owned-shared-view input-path)
    (owned_view.compiler-owned-shared-view stdlib-roots)
    (owned_view.compiler-owned-shared-view manifest-dir)
    deps
    emit-entry
    cfgs)
    [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths modules seen)
      (compiler_load.ResultCompilerLoadWithPaths.Ok
        (owned_view.compiler-owned-shared-view decls)
        (compiler_load.compiler-load-package-owned-paths-for-decls
          package-owner
          manifest-dir
          stdlib-roots
          input-path
          decls
          paths)
        modules
        seen)]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (compiler_load.ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-driver-ir-summary-line [name : String] [value : i64]) : String
  (str_cat.str-cat name " " (string.int->string value) "\n"))

(define (compiler-driver-ir-summary-render
  [summary : compiler_ir_types.CompilerIrSummary]) : String
  (let
    [out : String "typelisp-ir-summary v1\n"]
    (begin
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-driver-ir-summary-line
            "globals"
            (compiler_ir_types.compiler-ir-summary-globals summary))
          ""))
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-driver-ir-summary-line
            "functions"
            (compiler_ir_types.compiler-ir-summary-functions summary))
          ""))
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-driver-ir-summary-line
            "externs"
            (compiler_ir_types.compiler-ir-summary-externs summary))
          ""))
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-driver-ir-summary-line
            "blocks"
            (compiler_ir_types.compiler-ir-summary-blocks summary))
          ""))
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-driver-ir-summary-line
            "instructions"
            (compiler_ir_types.compiler-ir-summary-instructions summary))
          ""))
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-driver-ir-summary-line
            "vars"
            (compiler_ir_types.compiler-ir-summary-vars summary))
          ""))
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-driver-ir-summary-line
            "empty-blocks"
            (compiler_ir_types.compiler-ir-summary-empty-blocks summary))
          ""))
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-driver-ir-summary-line
            "max-instructions-function"
            (compiler_ir_types.compiler-ir-summary-max-instructions-function
              summary))
          ""))
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-driver-ir-summary-line
            "max-instructions-block"
            (compiler_ir_types.compiler-ir-summary-max-instructions-block
              summary))
          ""))
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-driver-ir-summary-line
            "call-arg-entries"
            (compiler_ir_types.compiler-ir-summary-call-arg-entries summary))
          ""))
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-driver-ir-summary-line
            "phi-input-entries"
            (compiler_ir_types.compiler-ir-summary-phi-input-entries summary))
          ""))
      (str_cat.str-cat
        out
        (compiler-driver-ir-summary-line
          "score"
          (compiler_ir_types.compiler-ir-summary-score summary))
        ""))))

(define (compiler-driver-emit-ir-summary-lowered-with-level
  [pools : compiler_ast_types.AstNodePoolContext]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [opt-level : i64]
  [profile-state : profile_state.CompilerProfileState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerDriver
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriver.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic "")))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower-for-job!
        typecheck-state)
      (compiler-driver-retire-frontend-arena!)
      (match (compiler_optimize.optimize-program-with-spans-and-pools-and-level-and-profile-state
        (owned_view.compiler-owned-shared-view pools)
        program
        spans
        opt-level
        profile-state)
        [(compiler_optimize.CompilerOptimizedProgram.Program optimized _)
          (begin
            (compiler-driver-release-lowered-ir! opt-level)
            (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerDriver.Err
                (box (compiler-driver-ty-node-pool-exhausted-diagnostic "")))
              (ResultCompilerDriver.Ok
                (compiler-driver-ir-summary-render
                  (compiler_ir_types.compiler-ir-program-summary optimized)))))]))))

(define (compiler-driver-emit-ir-summary-lowered-result-with-level
  [lowered : ResultCompilerDriverLowered]
  [opt-level : i64]) : ResultCompilerDriver
  (match lowered
    [(ResultCompilerDriverLowered.Ok
        program
        spans
        pools
        profile-state
        _backend-state
        typecheck-state)
      (let
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              (owned_view.compiler-owned-shared-view pools)
              program)
            program)]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerDriver
          (begin
            (compiler_ast_types.ast-node-pool-reader-use!
              (owned_view.compiler-owned-shared-view pools))
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-driver-emit-ir-summary-lowered-with-level
              pools
              emit-program
              emit-spans
              opt-level
              profile-state
              typecheck-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (compiler_ast_types.ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriver.Err diag))]))

(define (compiler-driver-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : compiler_backend.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
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
  [target : compiler_backend.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriver
  (compiler-driver-emit-ir-summary-lowered-result-with-level
    (compiler-driver-load-and-lower-pic-image-with-state
      (owned_view.compiler-owned-shared-view state)
      input-path
      target
      stdlib-roots
      mode
      (compiler-driver-state-target-cfgs
        (owned_view.compiler-owned-shared-view state)
        target
        cfgs))
    opt-level))

(define (compiler-driver-ir-text-result
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [optimized : compiler_ir_types.CompilerIrProgram]
  [dump-pass : String]) : ResultCompilerDriver
  (let
    [verify-error : String
      (compiler_optimize.compiler-opt-debug-verification-error)]
    (if (> (string.string-length verify-error) 0)
      (ResultCompilerDriver.Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            (str_cat.str-cat "IR verification failed: " verify-error))))
      (let
        [text : String
          (if (> (string.string-length dump-pass) 0)
            (compiler_optimize.compiler-opt-debug-dump-result)
            (compiler_ir_types.compiler-ir-program-render
              structural-session
              type-segment-bases
              optimized))]
        (if (and
          (> (string.string-length dump-pass) 0)
          (= (string.string-length text) 0))
          (ResultCompilerDriver.Err
            (box
              (compiler_diagnostic.compiler-diagnostic-at-start
                ""
                (str_cat.str-cat "optimizer pass '" dump-pass "' did not run"))))
          (ResultCompilerDriver.Ok text))))))

(define (compiler-driver-emit-ir-text-lowered-with-level
  [pools : compiler_ast_types.AstNodePoolContext]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [opt-level : i64]
  [dump-pass : String]
  [profile-state : profile_state.CompilerProfileState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : ResultCompilerDriver
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (ResultCompilerDriver.Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic "")))
    (begin
      (compiler-driver-release-typecheck-caches-after-lower-for-job!
        typecheck-state)
      (compiler-driver-retire-frontend-arena!)
      (match (compiler_optimize.optimize-program-with-spans-and-pools-and-level-and-profile-state
        (owned_view.compiler-owned-shared-view pools)
        program
        spans
        opt-level
        profile-state)
        [(compiler_optimize.CompilerOptimizedProgram.Program optimized _)
          (begin
            (compiler-driver-release-lowered-ir! opt-level)
            (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
              (ResultCompilerDriver.Err
                (box (compiler-driver-ty-node-pool-exhausted-diagnostic "")))
              (compiler-driver-ir-text-result
                (cis.intern-structural-session-handle-from-source-names
                  (compiler_typecheck_core.tc-macro-state-source-names
                    (compiler_typecheck_core.tc-job-state-macro-state
                      typecheck-state)))
                (compiler_ast_types.ast-node-pool-context-type-segment-bases
                  pools)
                optimized
                dump-pass)))]))))

(define (compiler-driver-emit-ir-text-lowered-result-with-level
  [lowered : ResultCompilerDriverLowered]
  [opt-level : i64]
  [dump-pass : String]) : ResultCompilerDriver
  (match lowered
    [(ResultCompilerDriverLowered.Ok
        program
        spans
        pools
        profile-state
        _backend-state
        typecheck-state)
      (let
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              (owned_view.compiler-owned-shared-view pools)
              program)
            program)]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone spans)
            spans)]
        [out : ResultCompilerDriver
          (begin
            (compiler_ast_types.ast-node-pool-reader-use!
              (owned_view.compiler-owned-shared-view pools))
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-driver-emit-ir-text-lowered-with-level
              pools
              emit-program
              emit-spans
              opt-level
              dump-pass
              profile-state
              typecheck-state))]
        (begin
          (if (= opt-level 0)
            (compiler-driver-retire-lowered-source-arena!)
            unit)
          (compiler_ast_types.ast-node-pool-reader-clear!)
          (compiler-driver-restore-frontend-return-arena!)
          out))]
    [(ResultCompilerDriverLowered.Err diag)
      (begin
        (compiler-driver-restore-frontend-return-arena!)
        (ResultCompilerDriver.Err diag))]))

(define (compiler-driver-state-emit-ir-text-file-with-target-roots-level-mode-and-cfg
  [state : CompilerDriverState]
  [input-path : String]
  [target : compiler_backend.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [dump-pass : String]) : ResultCompilerDriver
  (compiler-driver-emit-ir-text-lowered-result-with-level
    (compiler-driver-load-and-lower-pic-image-with-state
      (owned_view.compiler-owned-shared-view state)
      input-path
      target
      stdlib-roots
      mode
      (compiler-driver-state-target-cfgs
        (owned_view.compiler-owned-shared-view state)
        target
        cfgs))
    opt-level
    dump-pass))

(define (compiler-driver-write-text-buf
  [output-path : String]
  [buf : text_buf.TextBuf]) : i64
  (text_buf.write-file output-path buf))

;; Human-facing compiler commands render the diagnostic against its primary
;; source file. Keep `compiler-diagnostic-render` as the stable flat form for
;; LSP, public-tool, and other machine-readable consumers.
(define (compiler-driver-render-source-diagnostic
  [diag : compiler_diagnostic.CompilerDiagnostic]) : String
  (let
    [path : String (compiler_diagnostic.compiler-diagnostic-path diag)]
    (if (string.eq path "")
      (compiler_diagnostic.compiler-diagnostic-render-source diag "")
      (match (io.try-read-file (& path))
        [(io.OkIoBytes source)
          (compiler_diagnostic.compiler-diagnostic-render-source
            diag
            (byte_buf.to-string source))]
        [(io.ErrIoBytes _)
          (compiler_diagnostic.compiler-diagnostic-render-source diag "")]))))

(define (compiler-driver-write-result
  [_profile-state : profile_state.CompilerProfileState]
  [result : ResultCompilerDriver]
  [output-path : String]) : i64
  (match result
    [(ResultCompilerDriver.Ok asm)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-start-phase
            (profile_state.compiler-profile-state-shared-view _profile-state)))
        (io.write-file output-path (byte_buf.str-as-bytes (& asm)))
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase
            (profile_state.compiler-profile-state-shared-view _profile-state)
            "write"))
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total
            (profile_state.compiler-profile-state-shared-view _profile-state)))
        (io.print-format "{}" (str_cat.str-cat "Wrote " output-path "\n"))
        0)]
    [(ResultCompilerDriver.Err diag)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total
            (profile_state.compiler-profile-state-shared-view _profile-state)))
        (io.print-error
          (compiler-driver-render-source-diagnostic
            (owned_view.compiler-owned-box-shared-view diag)))
        1)]))

(define (compiler-driver-write-buffer-result
  [_profile-state : profile_state.CompilerProfileState]
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [result : ResultCompilerDriverBuffer]
  [output-path : String]) : i64
  (match result
    [(ResultCompilerDriverBuffer.Ok buf)
      (let
        [status : i64
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-start-phase
                (profile_state.compiler-profile-state-shared-view
                  _profile-state)))
            (compiler-driver-write-text-buf
              (owned_view.compiler-owned-shared-view output-path)
              buf))]
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (profile_state.compiler-profile-state-shared-view _profile-state)
              "write"))
          (compiler-driver-allocation-profile-snapshot-for-job!
            typecheck-state
            "write")
          (cfg
            compile-profile
            (compiler-driver-profile-finish-total
              (profile_state.compiler-profile-state-shared-view _profile-state)))
          (if (= status 0)
            (begin
              (io.print-format "{}" (str_cat.str-cat "Wrote " output-path "\n"))
              0)
            status)))]
    [(ResultCompilerDriverBuffer.Err diag)
      (begin
        (compiler-driver-allocation-profile-snapshot-for-job!
          typecheck-state
          "write-error")
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total
            (profile_state.compiler-profile-state-shared-view _profile-state)))
        (io.print-error
          (compiler-driver-render-source-diagnostic
            (compiler_diagnostic.compiler-diagnostic-box-shared-view
              (owned_view.compiler-owned-shared-view diag))))
        1)]))

(define (compiler-driver-pic-fixups-path [output-path : String]) : String
  (str_cat.str-cat output-path ".fixups"))

(define (compiler-driver-write-pic-result
  [_profile-state : profile_state.CompilerProfileState]
  [result : ResultCompilerDriverPic]
  [output-path : String]) : i64
  (match result
    [(ResultCompilerDriverPic.Ok output)
      (let
        [fixups-path : String
          (compiler-driver-pic-fixups-path
            (owned_view.compiler-owned-shared-view output-path))]
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase
              (profile_state.compiler-profile-state-shared-view _profile-state)))
          (let
            [asm : String output.asm]
            [fixups : String output.fixups]
            (begin
              (io.write-file output-path (byte_buf.str-as-bytes (& asm)))
              (io.write-file fixups-path (byte_buf.str-as-bytes (& fixups)))))
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (profile_state.compiler-profile-state-shared-view _profile-state)
              "write"))
          (cfg
            compile-profile
            (compiler-driver-profile-finish-total
              (profile_state.compiler-profile-state-shared-view _profile-state)))
          (io.print-format "{}" (str_cat.str-cat "Wrote " output-path "\n"))
          (io.print-format "{}" (str_cat.str-cat "Wrote " fixups-path "\n"))
          0))]
    [(ResultCompilerDriverPic.Err diag)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total
            (profile_state.compiler-profile-state-shared-view _profile-state)))
        (io.print-error
          (compiler-driver-render-source-diagnostic
            (owned_view.compiler-owned-box-shared-view diag)))
        1)]))