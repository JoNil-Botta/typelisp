;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.
(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import compiler_owned_view as owned_view)
(import compiler_surface_facts as surface_facts)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)
(import (vector.vector String) as svec)
(cfg compile-profile (import stdlib.profile))
(import compiler_allocation_profile as allocation_profile)
(import compiler_profile_state as profile_state)
(cfg (any compile-profile test) (import compiler_profile_counters as counters))
(import compiler_backend)
(import compiler_ast_types)
(import compiler_typecheck_core)
(import compiler_parse_core)
(import compiler_lower)
(import compiler_ir_types)
(import compiler_ctfe)
(import compiler_object as cobj)
(import compiler_builtin_ids as cbi)
(import compiler_cfg_core as cfg_core)
(import compiler_target_cfg_core as target_cfg)
(import compiler_diagnostic)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_load)
(import compiler_tli_compact_ir as tli_compact_ir)
(import tli_cli_core as tli_cli)
(cfg embedded-stdlib-tlci (import compiler_build_identity as build_identity))
(cfg
  embedded-stdlib-tlci
  (import compiler_surface_identity as surface_identity))
(cfg embedded-stdlib-tlci (import compiler_surface_ast as surface_ast))
(cfg embedded-stdlib-tlci (import compiler_surface_hydrate))
(cfg
  embedded-stdlib-tlci
  (import compiler_embedded_stdlib_tlci as embedded_tlci))
(cfg embedded-stdlib-tlci (import tlci_core as tlci))
(cfg
  compile-startup-profile
  (import compiler_startup_profile as startup_profile))

(define (driver-clone-spmd-form [form : (& compiler_ir_types.CompilerSpmdForm)]) : compiler_ir_types.CompilerSpmdForm
  (match form
    [(compiler_ir_types.CompilerSpmdForm.Foreach)
      compiler_ir_types.CompilerSpmdForm.Foreach]
    [(compiler_ir_types.CompilerSpmdForm.Reduce)
      compiler_ir_types.CompilerSpmdForm.Reduce]
    [(compiler_ir_types.CompilerSpmdForm.Scan)
      compiler_ir_types.CompilerSpmdForm.Scan]
    [(compiler_ir_types.CompilerSpmdForm.Compact)
      compiler_ir_types.CompilerSpmdForm.Compact]
    [(compiler_ir_types.CompilerSpmdForm.Broadcast)
      compiler_ir_types.CompilerSpmdForm.Broadcast]
    [(compiler_ir_types.CompilerSpmdForm.Shuffle)
      compiler_ir_types.CompilerSpmdForm.Shuffle]))

(define (driver-clone-spmd-backend
  [backend : (& compiler_ir_types.CompilerSpmdBackend)]) : compiler_ir_types.CompilerSpmdBackend
  (match backend
    [(compiler_ir_types.CompilerSpmdBackend.Scalar)
      compiler_ir_types.CompilerSpmdBackend.Scalar]
    [(compiler_ir_types.CompilerSpmdBackend.Avx2)
      compiler_ir_types.CompilerSpmdBackend.Avx2]
    [(compiler_ir_types.CompilerSpmdBackend.Avx512)
      compiler_ir_types.CompilerSpmdBackend.Avx512]))

(define (driver-clone-spmd-route
  [route : (& compiler_ir_types.CompilerSpmdRoute)]) : compiler_ir_types.CompilerSpmdRoute
  (match route
    [(compiler_ir_types.CompilerSpmdRoute.NativeGangs)
      compiler_ir_types.CompilerSpmdRoute.NativeGangs]
    [(compiler_ir_types.CompilerSpmdRoute.CompilerFallback)
      compiler_ir_types.CompilerSpmdRoute.CompilerFallback]
    [(compiler_ir_types.CompilerSpmdRoute.SpecifiedScalar)
      compiler_ir_types.CompilerSpmdRoute.SpecifiedScalar]
    [(compiler_ir_types.CompilerSpmdRoute.ScalarBackend)
      compiler_ir_types.CompilerSpmdRoute.ScalarBackend]
    [(compiler_ir_types.CompilerSpmdRoute.Inactive)
      compiler_ir_types.CompilerSpmdRoute.Inactive]
    [(compiler_ir_types.CompilerSpmdRoute.Rejected)
      compiler_ir_types.CompilerSpmdRoute.Rejected]))

(define (driver-clone-spmd-reason
  [reason : (& compiler_ir_types.CompilerSpmdReason)]) : compiler_ir_types.CompilerSpmdReason
  (match reason
    [(compiler_ir_types.CompilerSpmdReason.DirectMap)
      compiler_ir_types.CompilerSpmdReason.DirectMap]
    [(compiler_ir_types.CompilerSpmdReason.MaskedMap)
      compiler_ir_types.CompilerSpmdReason.MaskedMap]
    [(compiler_ir_types.CompilerSpmdReason.ContiguousReduction)
      compiler_ir_types.CompilerSpmdReason.ContiguousReduction]
    [(compiler_ir_types.CompilerSpmdReason.FusedReduction)
      compiler_ir_types.CompilerSpmdReason.FusedReduction]
    [(compiler_ir_types.CompilerSpmdReason.ContiguousScan)
      compiler_ir_types.CompilerSpmdReason.ContiguousScan]
    [(compiler_ir_types.CompilerSpmdReason.ScalarBackendSelected)
      compiler_ir_types.CompilerSpmdReason.ScalarBackendSelected]
    [(compiler_ir_types.CompilerSpmdReason.OrderedCompact)
      compiler_ir_types.CompilerSpmdReason.OrderedCompact]
    [(compiler_ir_types.CompilerSpmdReason.ExplicitAtomic)
      compiler_ir_types.CompilerSpmdReason.ExplicitAtomic]
    [(compiler_ir_types.CompilerSpmdReason.ScalarCrossLane)
      compiler_ir_types.CompilerSpmdReason.ScalarCrossLane]
    [(compiler_ir_types.CompilerSpmdReason.IndexType)
      compiler_ir_types.CompilerSpmdReason.IndexType]
    [(compiler_ir_types.CompilerSpmdReason.MapShape)
      compiler_ir_types.CompilerSpmdReason.MapShape]
    [(compiler_ir_types.CompilerSpmdReason.DuplicateDestination)
      compiler_ir_types.CompilerSpmdReason.DuplicateDestination]
    [(compiler_ir_types.CompilerSpmdReason.DependentStores)
      compiler_ir_types.CompilerSpmdReason.DependentStores]
    [(compiler_ir_types.CompilerSpmdReason.MixedLaneShape)
      compiler_ir_types.CompilerSpmdReason.MixedLaneShape]
    [(compiler_ir_types.CompilerSpmdReason.ReductionValueShape)
      compiler_ir_types.CompilerSpmdReason.ReductionValueShape]
    [(compiler_ir_types.CompilerSpmdReason.ScanInputShape)
      compiler_ir_types.CompilerSpmdReason.ScanInputShape]
    [(compiler_ir_types.CompilerSpmdReason.ScanOutputShape)
      compiler_ir_types.CompilerSpmdReason.ScanOutputShape]
    [(compiler_ir_types.CompilerSpmdReason.LaneType)
      compiler_ir_types.CompilerSpmdReason.LaneType]
    [(compiler_ir_types.CompilerSpmdReason.Operator)
      compiler_ir_types.CompilerSpmdReason.Operator]
    [(compiler_ir_types.CompilerSpmdReason.NumericPolicy)
      compiler_ir_types.CompilerSpmdReason.NumericPolicy]
    [(compiler_ir_types.CompilerSpmdReason.VaryingWhile)
      compiler_ir_types.CompilerSpmdReason.VaryingWhile]
    [(compiler_ir_types.CompilerSpmdReason.VaryingIf)
      compiler_ir_types.CompilerSpmdReason.VaryingIf]
    [(compiler_ir_types.CompilerSpmdReason.VaryingEnumMatch)
      compiler_ir_types.CompilerSpmdReason.VaryingEnumMatch]
    [(compiler_ir_types.CompilerSpmdReason.VaryingMatch)
      compiler_ir_types.CompilerSpmdReason.VaryingMatch]
    [(compiler_ir_types.CompilerSpmdReason.ShuffleShape)
      compiler_ir_types.CompilerSpmdReason.ShuffleShape]
    [(compiler_ir_types.CompilerSpmdReason.UnsupportedShift)
      compiler_ir_types.CompilerSpmdReason.UnsupportedShift]
    [(compiler_ir_types.CompilerSpmdReason.UnsupportedMap)
      compiler_ir_types.CompilerSpmdReason.UnsupportedMap]
    [(compiler_ir_types.CompilerSpmdReason.ForeachActive)
      compiler_ir_types.CompilerSpmdReason.ForeachActive]
    [(compiler_ir_types.CompilerSpmdReason.PrivateHelper)
      compiler_ir_types.CompilerSpmdReason.PrivateHelper]
    [(compiler_ir_types.CompilerSpmdReason.NotLowered)
      compiler_ir_types.CompilerSpmdReason.NotLowered]
    [(compiler_ir_types.CompilerSpmdReason.UnsupportedSource)
      compiler_ir_types.CompilerSpmdReason.UnsupportedSource]))

(define (driver-clone-source-location
  [location : (& compiler_ir_types.CompilerSourceLocation)]) : compiler_ir_types.CompilerSourceLocation
  (compiler_ir_types.CompilerSourceLocation
    location.path-id
    (compiler_ast_types.clone-ast-source-span (& location.span))))

(define (driver-clone-spmd-decision
  [item : (& compiler_ir_types.CompilerSpmdDecision)]) : compiler_ir_types.CompilerSpmdDecision
  (compiler_ir_types.CompilerSpmdDecision
    (compiler_ir_types.CompilerSpmdSiteId
      (compiler_ir_types.CompilerIrSymbolId item.site.function.value)
      item.site.ordinal)
    item.parent-ordinal
    (driver-clone-spmd-form (& item.form))
    (driver-clone-spmd-backend (& item.backend))
    item.lanes
    (driver-clone-spmd-route (& item.route))
    (driver-clone-spmd-reason (& item.reason))
    (driver-clone-source-location (& item.primary))
    (driver-clone-source-location (& item.actionable))
    item.frame-start
    item.frame-count))

(define (driver-clone-source-spans-entry
  [item : (& compiler_ir_types.CompilerSourceSpansEntry)]) : compiler_ir_types.CompilerSourceSpansEntry
  (compiler_ir_types.CompilerSourceSpansEntry
    (compiler_ir_types.CompilerIrSymbolId item.name.value)
    item.path-id
    (compiler_ast_types.clone-ast-source-span (& item.span))))

(define (driver-clone-source-spans-instr-entry
  [item : (& compiler_ir_types.CompilerSourceSpansInstrEntry)]) : compiler_ir_types.CompilerSourceSpansInstrEntry
  (compiler_ir_types.CompilerSourceSpansInstrEntry
    (compiler_ir_types.CompilerIrSymbolId item.function.value)
    item.id
    item.path-id
    (compiler_ast_types.clone-ast-source-span (& item.span))
    item.kind))

(define (clone-compiler-source-spans
  [spans : (& compiler_ir_types.CompilerSourceSpans)]) : compiler_ir_types.CompilerSourceSpans
  (match spans
    [(compiler_ir_types.CompilerSourceSpans.Spans
        entries
        instructions
        count
        facts)
      (let
        [entry-count : i64 entries.len]
        [entry-slots : (__tl_dyn-array
          compiler_ir_types.CompilerSourceSpansEntry)
          (__tl_make-array
            compiler_ir_types.CompilerSourceSpansEntry
            entry-count)]
        [instr-count : i64 instructions.len]
        [instr-slots : (__tl_dyn-array
          compiler_ir_types.CompilerSourceSpansInstrEntry)
          (__tl_make-array
            compiler_ir_types.CompilerSourceSpansInstrEntry
            instr-count)]
        [decision-count : i64 facts.decisions.len]
        [decision-slots : (__tl_dyn-array
          compiler_ir_types.CompilerSpmdDecision)
          (__tl_make-array
            compiler_ir_types.CompilerSpmdDecision
            decision-count)]
        [frame-count : i64 facts.frames.len]
        [frame-slots : (__tl_dyn-array compiler_ir_types.CompilerSpmdMacroFrame)
          (__tl_make-array compiler_ir_types.CompilerSpmdMacroFrame frame-count)]
        (for [index (iterator.range 0 entry-count)]
          (set!
            (array-ref entry-slots index)
            (driver-clone-source-spans-entry
              (& (array-ref entries.slots index)))))
        (for [index (iterator.range 0 instr-count)]
          (set!
            (array-ref instr-slots index)
            (driver-clone-source-spans-instr-entry
              (& (array-ref instructions.slots index)))))
        (for [index (iterator.range 0 decision-count)]
          (set!
            (array-ref decision-slots index)
            (driver-clone-spmd-decision
              (& (array-ref facts.decisions.slots index)))))
        (for [index (iterator.range 0 frame-count)]
          (set!
            (array-ref frame-slots index)
            (compiler_ir_types.CompilerSpmdMacroFrame
              (array-ref facts.frames.slots index).name-id)))
        (compiler_ir_types.CompilerSourceSpans.Spans
          (compiler_ir_types.CompilerSourceSpansEntryList
            entry-slots
            entry-count)
          (compiler_ir_types.CompilerSourceSpansInstrEntryList
            instr-slots
            instr-count)
          count
          (compiler_ir_types.CompilerSpmdDecisions
            (compiler_ir_types.CompilerSpmdDecisionList
              decision-slots
              decision-count)
            (compiler_ir_types.CompilerSpmdMacroFrameList
              frame-slots
              frame-count))))]))

(import compiler_optimize)
(import compiler_opt_level as opt_level)
(import stdlib.text_buf)
(import sym_i64_env)

(defenum ResultCompilerDriver
  (Ok String compiler_diagnostic.CompilerAdvisoryList)
  (Err
    (Box compiler_diagnostic.CompilerDiagnostic)
    compiler_diagnostic.CompilerAdvisoryList))

(defenum ResultCompilerDriverBuffer
  (Ok text_buf.TextBuf compiler_diagnostic.CompilerAdvisoryList)
  (Err
    (Box compiler_diagnostic.CompilerDiagnostic)
    compiler_diagnostic.CompilerAdvisoryList))

(defenum ResultCompilerDriverPic
  (Ok
    be_state.CompilerBackendPicOutput
    compiler_diagnostic.CompilerAdvisoryList)
  (Err
    (Box compiler_diagnostic.CompilerDiagnostic)
    compiler_diagnostic.CompilerAdvisoryList))

(defenum ResultCompilerDriverObject
  (Ok cobj.CompilerObjectImage compiler_diagnostic.CompilerAdvisoryList)
  (Unavailable
    be_state.CompilerDirectObjectFallbackReason
    compiler_diagnostic.CompilerAdvisoryList)
  (Err
    (Box compiler_diagnostic.CompilerDiagnostic)
    compiler_diagnostic.CompilerAdvisoryList))

(defenum ResultCompilerDriverPackageRuntime
  (Object
    cobj.CompilerObjectImage
    String
    compiler_diagnostic.CompilerAdvisoryList)
  (Assembly
    String
    be_state.CompilerDirectObjectFallbackReason
    compiler_diagnostic.CompilerAdvisoryList)
  (Err
    (Box compiler_diagnostic.CompilerDiagnostic)
    compiler_diagnostic.CompilerAdvisoryList))

(defenum ResultCompilerDriverLowered
  (Ok
    compiler_ir_types.CompilerIrProgram
    compiler_ir_types.CompilerSourceSpans
    compiler_ast_types.AstNodePoolContext
    profile_state.CompilerProfileState
    be_state.CompilerBackendState
    compiler_typecheck_core.TcJobState
    compiler_lower.CompilerLowerState)
  (Err
    (Box compiler_diagnostic.CompilerDiagnostic)
    compiler_diagnostic.CompilerAdvisoryList))

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
  (backend-state be_state.CompilerBackendState)
  (typecheck-prefix-cache compiler_typecheck_core.TcPrefixSnapshotCacheState)
  (pool-arena (__tl_dyn-array i64))
  (surface-arena i64)
  (profile-state profile_state.CompilerProfileState))

;; The three state fragments intentionally allocated in the driver's retained
;; surface arena. Keeping the bundle local to construction lets one `in-arena`
;; extent preserve their allocation order while restoring the caller before
;; the outer state installs any of them.
(defenum CompilerDriverSurfaceState
  (State compiler_typecheck_core.TcJobState i64 be_state.CompilerBackendState))

(define (compiler-driver-state-new-from-pools-arena-and-load-session
  [expr-pool : compiler_ast_types.AstExprNodePoolState]
  [type-pool : compiler_ast_types.AstTypeNodePoolState]
  [pool-arena : i64]
  [load-session : compiler_load.CompilerLoadSessionState]) : CompilerDriverState
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
        (unsafe
          (arena.Arena surface-arena))
        (State
          (cfg
            (any compile-profile test)
            (compiler_typecheck_core.tc-job-state-new-with-profile-metrics-address
              (profile_state.compiler-profile-state-typecheck-metrics-address
                profile-state))
            (compiler_typecheck_core.tc-job-state-new))
          (__tl-project-field
            (compiler_lower.compiler-lower-state-new-with-intern-state-and-profile-state
              (owned_view.compiler-owned-shared-view intern-state)
              profile-state)
            address)
          (be_state.compiler-backend-state-new-with-metrics
            (owned_view.compiler-owned-shared-view intern-state)
            (profile_state.compiler-profile-state-metrics profile-state))))]
    (match surface-state
      [(State typecheck-state lower-state-address backend-state)
        (set! (array-ref expr-cell 0) expr-pool)
        (set! (array-ref type-cell 0) type-pool)
        (set! (array-ref intern-cell 0) intern-state)
        (set! (array-ref builtin-cell 0) (cbi.state-new))
        (set! (array-ref lower-cell 0) lower-state-address)
        (set! (array-ref pool-arena-cell 0) pool-arena)
        (let
          [advisory-sink : compiler_diagnostic.CompilerAdvisorySink
            (compiler_typecheck_core.tc-job-state-advisory-sink typecheck-state)]
          (compiler_lower.compiler-lower-state-use-advisory-sink!
            (compiler_lower.compiler-lower-state-from-address
              lower-state-address)
            advisory-sink)
          (be_state.compiler-backend-state-set-advisory-sink!
            backend-state
            advisory-sink))
        (let
          [parser-state : compiler_parse_core.CompilerParseState
            (compiler_parse_core.compiler-parse-state-new-with-intern-state
              (owned_view.compiler-owned-array-element-shared-view
                intern-cell
                0))]
          (compiler_typecheck_core.tc-job-state-set-parser-control!
            typecheck-state
            (compiler_parse_core.compiler-parse-state-control-addr
              (& parser-state)))
          (CompilerDriverState
            expr-cell
            type-cell
            (owned_view.compiler-owned-shared-view intern-cell)
            parser-state
            builtin-cell
            lower-cell
            load-session
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

(define (compiler-driver-state-detach-active-pools-if-owned!
  [pools : compiler_ast_types.AstNodePoolContext]) : unit
  (if (=
    (compiler_ast_types.ast-node-pool-owner-arena-handle)
    (compiler_ast_types.ast-node-pool-context-owner-arena pools))
    (compiler_ast_types.ast-node-pool-context-install!
      (array-ref compiler-driver-detached-compat-pools 0))
    unit))

(define (compiler-driver-state-new-for-compile-with-load-session
  [load-session : compiler_load.CompilerLoadSessionState]) : CompilerDriverState
  (let
    [pool-arena : i64 (compiler_ast_types.ast-node-pool-arena-make)]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-new-with-capacities-in-arena
        compiler-driver-compile-load-expr-pool-initial-capacity
        compiler-driver-compile-type-pool-initial-capacity
        pool-arena)]
    [state : CompilerDriverState
      (compiler-driver-state-new-from-pools-arena-and-load-session
        (compiler_ast_types.ast-expr-pool-cell-read pools.expr-pool)
        (compiler_ast_types.ast-type-pool-cell-read pools.type-pool)
        (compiler_ast_types.ast-node-pool-context-base-arena pools)
        load-session)]
    (cbi.state-capture-from-globals! (&mut (array-ref state.builtin-ids 0)))
    state))

(define (compiler-driver-state-new-for-compile) : CompilerDriverState
  (compiler-driver-state-new-for-compile-with-load-session
    (compiler_load.compiler-load-session-state-new)))

(define (compiler-driver-state-session-cache-enabled?
  [state : (& state CompilerDriverState)]) : bool
  (compiler_load.compiler-load-session-state-cache-enabled? state.load-session))

(define (compiler-driver-state-profile [state : (& state CompilerDriverState)]) : profile_state.CompilerProfileState
  (let
    [state : CompilerDriverState
      (owned_view.compiler-owned-reference-shared-view state)]
    state.profile-state))

(define (compiler-driver-state-backend [state : (& state CompilerDriverState)]) : be_state.CompilerBackendState
  (let
    [state : CompilerDriverState
      (owned_view.compiler-owned-reference-shared-view state)]
    state.backend-state))

(define (compiler-driver-state-typecheck
  [state : (& state CompilerDriverState)]) : compiler_typecheck_core.TcJobState
  (let
    [state : CompilerDriverState
      (owned_view.compiler-owned-reference-shared-view state)]
    state.typecheck-state))

(define (compiler-driver-state-advisory-sink [state : CompilerDriverState]) : compiler_diagnostic.CompilerAdvisorySink
  (compiler_typecheck_core.tc-job-state-advisory-sink state.typecheck-state))

(define (compiler-driver-state-advisories [state : CompilerDriverState]) : compiler_diagnostic.CompilerAdvisoryList
  (compiler_diagnostic.compiler-advisory-sink-snapshot
    (compiler-driver-state-advisory-sink state)))

(define (compiler-driver-advisories-for-job
  [typecheck-state : compiler_typecheck_core.TcJobState]) : compiler_diagnostic.CompilerAdvisoryList
  (compiler_diagnostic.compiler-advisory-sink-snapshot
    (compiler_typecheck_core.tc-job-state-advisory-sink typecheck-state)))

(define (compiler-driver-serial-advisories) : compiler_diagnostic.CompilerAdvisoryList
  (compiler-driver-advisories-for-job
    (compiler_typecheck_core.tc-serial-job-state)))

(define (compiler-driver-state-reset-typecheck! [state : CompilerDriverState]) : unit
  (compiler_typecheck_core.tc-job-state-reset-file-state!
    (compiler-driver-state-typecheck state))
  (compiler_typecheck_core.tc-job-state-release-selected-file-storage!
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
      (compiler-driver-state-typecheck state))
    (compiler-driver-state-source-name-session-in-current state)))

(define (compiler-driver-state-prefix-cache-enable!
  [state : (& state CompilerDriverState)]) : unit
  (compiler_typecheck_core.tc-prefix-snapshot-cache-enable-for-state!
    state.typecheck-prefix-cache))

;: A batch keeps each stdlib module's trusted-source proof across its entries
;: (#8765); release drops them when the batch ends.
(define (compiler-driver-state-retain-stdlib-proofs!
  [state : (& state CompilerDriverState)]) : unit
  (compiler_load.compiler-load-session-state-retain-stdlib-proofs!
    (& state.load-session)))

(define (compiler-driver-state-release-stdlib-proofs!
  [state : (& state CompilerDriverState)]) : unit
  (compiler_load.compiler-load-session-state-release-stdlib-proofs!
    (& state.load-session)))

(define (compiler-driver-state-prefix-cache-disable!
  [state : CompilerDriverState]) : unit
  (compiler_typecheck_core.tc-prefix-snapshot-cache-disable-for-state!
    state.typecheck-prefix-cache))

(define (compiler-driver-state-prefix-cache-clear!
  [state : (& state CompilerDriverState)]) : unit
  (compiler_typecheck_core.tc-prefix-snapshot-cache-clear-for-state!
    state.typecheck-prefix-cache))

(define (compiler-driver-state-prefix-cache-print-stats
  [state : (& state CompilerDriverState)]
  [label : String]) : unit
  (compiler_typecheck_core.tc-prefix-snapshot-cache-print-stats-for-state
    state.typecheck-prefix-cache
    label))

(define (compiler-driver-state-session-program-cache-disable
  [state : CompilerDriverState]) : CompilerDriverState
  ;; The session is a handle: disable its cells through a view, keeping
  ;; `state` whole.
  (compiler_load.compiler-load-session-state-program-cache-disable!
    (owned_view.compiler-owned-shared-view state.load-session))
  state)

(define (compiler-driver-state-apply-session-flags!
  [state : CompilerDriverState]) : unit
  (compiler_load.compiler-load-session-state-use-with-intern-state!
    state.load-session
    (owned_view.compiler-owned-array-element-shared-view state.intern-state 0)))

;; Legacy/test adapter for compiler phases that still use the active pool
;; globals. State-owned reset/adopt operations must not call this helper.
(define (compiler-driver-state-install-pools!
  [state : (& state CompilerDriverState)]) : unit
  (set!
    (array-ref compiler-driver-active-state-pool-arena 0)
    (compiler-driver-state-owned-pool-arena state))
  (set!
    (array-ref compiler-driver-active-state-surface-arena 0)
    (compiler-driver-state-surface-arena state))
  (compiler_ast_types.ast-node-pool-context-install!
    (compiler-driver-state-pool-context state)))

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
(define (compiler-driver-state-install-interns!
  [state : (& state CompilerDriverState)]) : unit
  (ci.intern-compat-state-install! (array-ref state.intern-state 0)))

(define (compiler-driver-node-pool-base-arena) : i64
  (compiler_ast_types.ast-node-pool-base-arena-handle))

;; Emit owner candidates plus the active arena at stable compiler phase
;; boundaries. `arena_root` lets consumers de-duplicate an active arena that is
;; also one of the named owners.
(define (compiler-driver-allocation-profile-snapshot-for-job!
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [phase : String]
  [lower-state : compiler_lower.CompilerLowerState]) : unit
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
        (compiler_ast_types.ast-node-pool-expr-storage-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "type-pool-storage"
        (compiler_ast_types.ast-node-pool-type-storage-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "intern-persistent"
        (ci.intern-persistent-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "ir-labels"
        (compiler_ir_types.compiler-ir-label-arena-handle-value))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "ir-label-index"
        (compiler_ir_types.compiler-ir-label-generation-arena-handle-value))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "ir-symbols"
        (compiler_ir_types.compiler-ir-symbol-arena-handle-value))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "load-provenance"
        (compiler_load.compiler-load-session-state-provenance-arena-value
          (compiler_load.compiler-load-serial-test-session-state)))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "lexer-token-buffer"
        (compiler_load.compiler-load-lex-token-buffer-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "reader-node-pool"
        (compiler_load.compiler-load-reader-node-pool-arena-handle))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "semantic-origin-storage"
        (let
          [control : i64
            (if (= typecheck-state.address 0)
              0
              (compiler_typecheck_core.tc-job-state-parser-control
                typecheck-state))]
          (if (= control 0)
            0
            (compiler_parse_core.compiler-parse-origin-word
              (compiler_parse_core.compiler-parse-origin-storage control)
              0))))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "typecheck-aggregate-layout-cache"
        (compiler_typecheck_core.tc-agg-layout-cache-storage-arena-handle-value-for-job
          typecheck-state))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "lower-scratch"
        (if (= lower-state.address 0)
          0
          (compiler_lower.compiler-lower-arena-state-scratch-arena
            (& (compiler_lower.compiler-lower-state-arenas lower-state)))))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "lower-ir"
        (if (= lower-state.address 0)
          0
          (compiler_lower.compiler-lower-arena-state-ir-arena
            (& (compiler_lower.compiler-lower-state-arenas lower-state)))))
      ;; A chunked lowered owner's bodies live in its live chunks, listed in
      ;; its chunk directory's own arena (#9059).
      (unless
        (= lower-state.address 0)
        (let
          [arenas : compiler_lower.CompilerLowerArenaState
            (compiler_lower.compiler-lower-state-arenas lower-state)]
          [directory-arena : i64
            (compiler_lower.compiler-lower-ir-chunk-directory-arena (& arenas))]
          [count : i64
            (compiler_lower.compiler-lower-ir-chunk-count (& arenas))]
          [chunk : i64 0]
          [_directory-row : i64
            (if (= directory-arena 0)
              0
              (allocation_profile.compiler-allocation-profile-control!
                2
                phase
                "lower-ir-chunks"
                directory-arena))]
          (while (< chunk count)
            (let
              [handle : i64
                (compiler_lower.compiler-lower-ir-chunk-handle (& arenas) chunk)]
              [_chunk-row : i64
                (if (= handle 0)
                  0
                  (allocation_profile.compiler-allocation-profile-control!
                    2
                    phase
                    "lower-ir-chunk"
                    handle))]
              (set! chunk (+ chunk 1))))))
      unit)))

;; Command start/complete have no selected lower job. Job phase snapshots
;; supply their actual owner; zero here represents absence, never a selector.
(define (compiler-driver-allocation-profile-snapshot! [phase : String]) : unit
  (compiler-driver-allocation-profile-snapshot-for-job!
    (compiler_typecheck_core.TcJobState 0)
    phase
    (compiler_lower.CompilerLowerState 0)))

(define (compiler-driver-allocation-profile-pool-storage-snapshot!
  [phase : String]
  [pools : compiler_ast_types.AstNodePoolContext]) : unit
  (if (= (allocation_profile.compiler-allocation-profile-control! 0 "" "" 0) 0)
    unit
    (begin
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "expr-pool-storage"
        (compiler_ast_types.ast-node-pool-context-expr-storage-arena pools))
      (allocation_profile.compiler-allocation-profile-control!
        2
        phase
        "type-pool-storage"
        (compiler_ast_types.ast-node-pool-context-type-storage-arena pools))
      unit)))

(define (compiler-driver-state-prefix-cache-allocation-profile-snapshot!
  [state : (& state CompilerDriverState)]
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
  [backend-state : be_state.CompilerBackendState]) : unit
  (if (= (allocation_profile.compiler-allocation-profile-control! 0 "" "" 0) 0)
    unit
    (begin
      (allocation_profile.compiler-allocation-profile-control!
        2
        "backend"
        "backend-output-home"
        (be_state.compiler-backend-assembly-stream-home-arena-handle-value
          (be_state.compiler-backend-state-stream-state backend-state)))
      unit)))

(define (compiler-driver-state-pool-context
  [state : (& state CompilerDriverState)]) : compiler_ast_types.AstNodePoolContext
  (let
    [state : CompilerDriverState
      (owned_view.compiler-owned-reference-shared-view state)]
    (compiler_ast_types.ast-node-pool-context-from-cells
      state.expr-pool
      state.type-pool
      (array-ref state.pool-arena 0))))

(define (compiler-driver-state-owned-pool-arena
  [state : (& state CompilerDriverState)]) : i64
  (array-ref state.pool-arena 0))

(define (compiler-driver-state-surface-arena
  [state : (& state CompilerDriverState)]) : i64
  state.surface-arena)

(define (compiler-driver-state-has-owned-pool-arena?
  [state : (& state CompilerDriverState)]) : bool
  (not (= (compiler-driver-state-owned-pool-arena state) 0)))

(define (compiler-driver-state-adopt-pools!
  [state : (& state CompilerDriverState)]
  [pools : compiler_ast_types.AstNodePoolContext]) : unit
  (owned_view.compiler-owned-cell-set!
    state.pool-arena
    0
    (compiler_ast_types.ast-node-pool-context-base-arena pools))
  (set!
    (array-ref compiler-driver-active-state-pool-arena 0)
    (compiler_ast_types.ast-node-pool-context-base-arena pools))
  (owned_view.compiler-owned-cell-set!
    state.expr-pool
    0
    (compiler_ast_types.ast-expr-pool-cell-read pools.expr-pool))
  (owned_view.compiler-owned-cell-set!
    state.type-pool
    0
    (compiler_ast_types.ast-type-pool-cell-read pools.type-pool)))

(define (compiler-driver-state-can-release-checked-lower-source-pools?
  [state : (& state CompilerDriverState)]) : bool
  (and
    (compiler-driver-state-has-owned-pool-arena? state)
    (not (compiler-driver-state-session-cache-enabled? state))))

(define (compiler-driver-state-new-checked-lower-pools) : compiler_ast_types.AstNodePoolContext
  (let
    [pool-arena : i64 (compiler_ast_types.ast-node-pool-arena-make)]
    ;; Keep the context's wrapper cells with its backing arrays. Early source
    ;; retirement can otherwise unmap wrapper cells allocated in the frontend
    ;; arena before an error path gets a chance to release this pool.
    (in-arena
      (unsafe
        (arena.Arena pool-arena))
      (compiler_ast_types.ast-node-pool-context-new-with-capacities-in-arena
        compiler-driver-checked-lower-expr-pool-initial-capacity
        compiler-driver-compile-type-pool-initial-capacity
        pool-arena))))

(define (compiler-driver-state-destroy-uncommitted-pools!
  [pools : compiler_ast_types.AstNodePoolContext]) : unit
  ;; Checked lowering installs its destination pools into the compatibility
  ;; globals before it can fail. On an uncommitted error, detach that active
  ;; view before destroying the pool; otherwise batch cleanup can capture the
  ;; now-unmapped context cells after the diagnostic has been emitted.
  ;; Refs #5448.
  (compiler-driver-state-detach-active-pools-if-owned! pools)
  (compiler_ast_types.ast-node-pool-context-destroy-storage! pools)
  (unsafe
    (arena.tl_arena_destroy
      (compiler_ast_types.ast-node-pool-context-base-arena pools))))

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
      (compiler_ast_types.ast-node-pool-context-clone-types-only pools)]
    [retained-program : compiler_ir_types.CompilerIrProgram
      (in-arena
        (unsafe
          (arena.Arena
            (compiler_ast_types.ast-node-pool-context-base-arena retained)))
        (compiler_ir_types.compiler-ir-program-after-type-copy
          pools
          retained
          program))]
    (begin
      (compiler-driver-state-adopt-pools! state retained)
      ;; Optimizer/backend type reads use the explicit retained reader below.
      ;; Detach only when the active compatibility pool is the retiring source;
      ;; if another driver state owns it, leave that state's writer pool intact.
      (compiler-driver-state-detach-active-pools-if-owned! pools)
      (compiler_ast_types.ast-node-pool-context-type-retire! pools)
      ;; Standalone entry points can leave the retiring checked pool active;
      ;; move those to retained storage. Batch entry points instead have a
      ;; distinct caller-owned scratch arena that must remain active through
      ;; emission and be returned to batch cleanup.
      (if (= (arena.tl_arena_current) old-arena)
        (unsafe
          (arena.tl_arena_set
            (compiler_ast_types.ast-node-pool-context-base-arena retained)))
        unit)
      (compiler_ast_types.ast-node-pool-reader-use! retained)
      (compiler-driver-allocation-profile-pool-storage-snapshot!
        "retained-reader"
        retained)
      (cfg
        compile-profile
        (compiler_lower.compiler-lower-profile-pools "retained_reader" retained)
        unit)
      (set! compiler-driver-pending-retired-source-arena old-arena)
      (set!
        compiler-driver-pending-retired-source-expr-storage-arena
        old-expr-storage-arena)
      (set!
        compiler-driver-pending-retired-source-type-storage-arena
        old-type-storage-arena)
      (compiler-driver-lowered-from-pools-and-profile-state-and-backend-state
        retained-program
        spans
        retained
        (compiler-driver-state-profile state)
        (compiler-driver-state-backend state)
        (compiler-driver-state-typecheck state)
        (compiler-driver-state-owned-lower-state state)))))

(define (compiler-driver-state-clear-pool-backed-caches-for-state!
  [state : CompilerDriverState]) : unit
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
    state.typecheck-prefix-cache))

;; Serial compatibility adapter for the post-lowering arena retirement path.
(define (compiler-driver-state-clear-pool-backed-caches!) : unit
  (compiler_load.compiler-load-session-floors-set! 0 0 0)
  (compiler_load.compiler-load-program-cache-clear!)
  (compiler_load.compiler-load-runtime-prelude-cache-clear!)
  (compiler_typecheck_core.tc-prefix-snapshot-cache-clear!))

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
        (compiler_ast_types.ast-node-pool-context-base-arena
          (compiler-driver-state-pool-context state))]
      [new-arena : i64 (compiler_ast_types.ast-node-pool-arena-make)]
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
        (compiler-driver-state-pool-context state))
      (compiler_ast_types.ast-node-pool-context-destroy-storage!
        (compiler-driver-state-pool-context state))
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
        (set!
          (array-ref state.pool-arena 0)
          (compiler_ast_types.ast-node-pool-context-base-arena pools))
        ;; Keep the snapshot handle naming a live arena: the old pool
        ;; chain was destroyed above, and the next entry's load-phase
        ;; state-pool-arena row walks this global before any reinstall.
        (set!
          (array-ref compiler-driver-active-state-pool-arena 0)
          (compiler_ast_types.ast-node-pool-context-base-arena pools))
        (set!
          (array-ref state.expr-pool 0)
          (compiler_ast_types.ast-expr-pool-cell-read pools.expr-pool))
        (set!
          (array-ref state.type-pool 0)
          (compiler_ast_types.ast-type-pool-cell-read pools.type-pool))))))

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
  [state : (&mut state CompilerDriverState)]) : unit
  (if (or
    (not (compiler-driver-state-has-owned-pool-arena? state))
    (compiler-driver-state-session-cache-enabled? state))
    unit
    (begin
      (compiler_parse_core.compiler-parse-origin-reset!
        (compiler_parse_core.compiler-parse-array-data-addr
          state.parser-state.semantic-origins))
      ;; The driver state is shared; its intern cell is explicit interior
      ;; mutability.
      (let
        [cells : (__tl_dyn-array ci.InternCompatState)
          (owned_view.compiler-owned-reference-shared-view
            (& state.intern-state))]
        (ci.intern-compat-state-persistent-arena-reset!
          (&mut (array-ref cells 0)))
        unit))))

;; The state's owned builtin/CTFE id snapshot.
(define (compiler-driver-state-owned-builtins [state : CompilerDriverState]) : cbi.CompilerBuiltinIdsState
  (owned_view.compiler-owned-element-view state.builtin-ids 0))

;; The state's owned lower traversal/index/cache carrier.
(define (compiler-driver-state-owned-lower-state
  [state : (& state CompilerDriverState)]) : compiler_lower.CompilerLowerState
  (compiler_lower.compiler-lower-state-from-address
    (array-ref state.lower-state-address 0)))

;; The lower job owner composes the existing scratch/IR arena carrier.
(define (compiler-driver-state-owned-lower-arenas [state : CompilerDriverState]) : compiler_lower.CompilerLowerArenaState
  (compiler_lower.compiler-lower-state-arenas
    (compiler-driver-state-owned-lower-state state)))

;; Legacy/test capture paired with `compiler-driver-state-install-interns!`.
(define (compiler-driver-state-capture-active-interns!
  [state : (&mut state CompilerDriverState)]) : unit
  (let
    [cells : (__tl_dyn-array ci.InternCompatState)
      (owned_view.compiler-owned-reference-shared-view (& state.intern-state))]
    (ci.intern-compat-state-capture-from-globals! (&mut (array-ref cells 0)))
    unit))

(define (compiler-driver-state-intern-generation
  [state : (& state CompilerDriverState)]) : i64
  (ci.intern-compat-state-generation (array-ref state.intern-state 0)))

(define (compiler-driver-state-owned-interns
  [state : (& state CompilerDriverState)]) : ci.InternCompatState
  (let
    [state : CompilerDriverState
      (owned_view.compiler-owned-reference-shared-view state)]
    (owned_view.compiler-owned-element-view state.intern-state 0)))

;; The state's one-element intern cell array, a shallow view: the intern cell
;; is explicit interior mutability. A caller binds it and mutates
;; `(array-ref cells 0)`; a reference into a by-value state cannot be returned.
(define (compiler-driver-state-intern-cells [state : CompilerDriverState]) : (__tl_dyn-array
    ci.InternCompatState)
  (owned_view.compiler-owned-reference-shared-view (& state.intern-state)))

;; Allocate an immutable source-name snapshot in an explicit owner. Production
;; batch entries keep their snapshot in the rotating entry scratch arena; only
;; callers that explicitly request a retained driver capability use the
;; process-lived surface arena below.
(define (compiler-driver-state-source-name-session-in-arena
  [state : CompilerDriverState]
  [owner : i64]) : ci.InternSourceNameSessionHandle
  (in-arena
    (unsafe
      (arena.Arena owner))
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

(define (compiler-driver-state-capture-active-builtins!
  [state : (&mut state CompilerDriverState)]) : unit
  (let
    [cells : (__tl_dyn-array cbi.CompilerBuiltinIdsState)
      (owned_view.compiler-owned-reference-shared-view (& state.builtin-ids))]
    (cbi.state-capture-from-globals! (&mut (array-ref cells 0)))
    unit))

;; State-owned builtin reset: clears the state's own metadata and, only when
;; this state's table is the installed one, invalidates the compatibility
;; globals (CTFE builtin ids share the table and invalidate with it). No
;; install bridge: the next parse of this state re-derives the table.
(define (compiler-driver-state-reset-builtins! [state : CompilerDriverState]) : unit
  (let
    [cells : (__tl_dyn-array cbi.CompilerBuiltinIdsState)
      (owned_view.compiler-owned-reference-shared-view (& state.builtin-ids))]
    (cbi.state-reset! (&mut (array-ref cells 0)))
    unit))

;; Release only the arenas named by this job's own cells.
(define (compiler-driver-state-release-lower-arenas!
  [state : CompilerDriverState]) : unit
  (compiler_lower.compiler-lower-arena-state-release!
    (compiler-driver-state-owned-lower-arenas state)))

(define (compiler-driver-state-reset-lower! [state : CompilerDriverState]) : unit
  (compiler_lower.compiler-lower-state-reset!
    (compiler-driver-state-owned-lower-state state)))

;; Builtin compatibility state still needs capture after a batch entry.
;; Lower arena cells already retain their stable roots without installation.
(define (compiler-driver-state-capture-active-transients!
  [state : CompilerDriverState]) : unit
  (compiler-driver-state-capture-active-builtins! (&mut state)))

(define (compiler-driver-state-capture-session-floors!
  [state : CompilerDriverState]) : unit
  ;; Load/typecheck/lower mutate the state-owned context cells directly; do
  ;; not overwrite them from whichever compatibility pool happens to be
  ;; installed when a batch entry finishes, and do not install the loader's
  ;; serial/test selector as a compile-job handoff.
  (compiler-driver-state-capture-active-interns! (&mut state))
  (compiler-driver-state-capture-active-transients! state))

(define (compiler-driver-lowered-from-active-pools-and-profile-state-and-backend-state
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : be_state.CompilerBackendState]
  [lower-state : compiler_lower.CompilerLowerState]) : ResultCompilerDriverLowered
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (if (compiler_ast_types.ast-node-pool-compat-context-active?)
        (compiler_ast_types.ast-node-pool-compat-context-current)
        (compiler_ast_types.ast-node-pool-context-active-live))]
    (compiler-driver-lowered-from-pools-and-profile-state-and-backend-state
      program
      spans
      pools
      profile-state
      backend-state
      (compiler_typecheck_core.tc-serial-job-state)
      lower-state)))

(define (compiler-driver-lowered-from-active-pools-and-profile-state
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [profile-state : profile_state.CompilerProfileState]
  [lower-state : compiler_lower.CompilerLowerState]) : ResultCompilerDriverLowered
  (let
    [backend-state : be_state.CompilerBackendState
      (be_state.compiler-backend-state-new-with-metrics
        (ci.intern-compat-state-capture-active)
        (profile_state.compiler-profile-state-metrics profile-state))]
    (compiler-driver-lowered-from-active-pools-and-profile-state-and-backend-state
      program
      spans
      profile-state
      backend-state
      lower-state)))

(define (compiler-driver-lowered-from-pools-and-profile-state-and-backend-state
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [pools : compiler_ast_types.AstNodePoolContext]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : be_state.CompilerBackendState]
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [lower-state : compiler_lower.CompilerLowerState]) : ResultCompilerDriverLowered
  (let
    [snapshot : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-snapshot pools)]
    ;; The snapshot has a distinct state cell. Rebind owned evidence through
    ;; the checked canonical-prefix handoff, never by relaxing stamp identity.
    [published : compiler_ir_types.CompilerIrProgram
      (compiler_ir_types.compiler-ir-program-after-type-copy
        pools
        snapshot
        program)]
    (ResultCompilerDriverLowered.Ok
      published
      spans
      snapshot
      profile-state
      backend-state
      typecheck-state
      lower-state)))

(define (compiler-driver-runtime-prelude-cache-lookup-with-state
  [load-state : compiler_load.CompilerLoadSessionState]
  [key : (& key compiler_load.CompilerLoadPreludeCacheKey)]) : compiler_load.CompilerLoadPreludeCacheLookup
  (compiler_load.compiler-load-session-state-runtime-prelude-cache-lookup
    load-state
    key))

;; Helpers in this section that omit `load-state` are serial/test compatibility
;; adapters. Driver-owned compile paths call the explicit state-taking forms.
(define (compiler-driver-runtime-prelude-cache-lookup
  [key : (& key compiler_load.CompilerLoadPreludeCacheKey)]) : compiler_load.CompilerLoadPreludeCacheLookup
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
    (& key)
    (& decls)
    (& paths)
    (& modules)
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
    (& key)
    (& decls)
    (& paths)
    (& modules)
    seen
    pools))

(define (compiler-driver-ty-node-pool-exhausted-diagnostic
  [input-path : String]) : compiler_diagnostic.CompilerDiagnostic
  (compiler_diagnostic.compiler-diagnostic-at-start
    input-path
    (compiler_ast_types.ty-node-pool-exhausted-message)))

(define compiler-driver-last-hydrated-archive-path-state : String
  "")
(define compiler-driver-last-hydrated-archive-paths-state : (__tl_dyn-array
    String)
  (__tl_make-array String 0))
(define compiler-driver-last-hydrated-stdlib-state : bool
  false)

;; The last TLI session hydrated the prebuilt stdlib, whose archive needs the
;; full native runtime. Hydrated package archives alone do not.
(define (compiler-driver-last-hydrated-stdlib?) : bool
  compiler-driver-last-hydrated-stdlib-state)

(define (compiler-driver-last-hydrated-archive-path) : String
  (string.copy (& compiler-driver-last-hydrated-archive-path-state)))

(define (compiler-driver-last-hydrated-archive-paths) : (__tl_dyn-array String)
  (let
    [n : i64 (array-length compiler-driver-last-hydrated-archive-paths-state)]
    [out : (__tl_dyn-array String) (__tl_make-array String n)]
    (for [i (iterator.range 0 n)]
      (set!
        (array-ref out i)
        (string.copy
          (& (array-ref compiler-driver-last-hydrated-archive-paths-state i)))))
    out))

(define (compiler-driver-clear-last-hydrated-archive-path!) : unit
  (set! compiler-driver-last-hydrated-archive-path-state "")
  (set! compiler-driver-last-hydrated-stdlib-state false)
  (set!
    compiler-driver-last-hydrated-archive-paths-state
    (__tl_make-array String 0)))

(define (compiler-driver-target-cfg-from-backend
  [target : be_state.CompilerBackendTarget]) : target_cfg.CompilerTargetCfg
  (match target
    [(Linux) (target_cfg.CompilerTargetCfg.Linux)]
    [(Windows) (target_cfg.CompilerTargetCfg.Windows)]))

(define (compiler-driver-open-tli-catalog-for-session!
  [load-state : (& compiler_load.CompilerLoadSessionState)]
  [entry-path : (& str)]
  [target : target_cfg.CompilerTargetCfg]
  [stdlib-roots : (& svec.Vec)]
  [cfgs : sym_i64_env.SymI64Env]
  [opt-level : i64]
  [require-archive : bool]) : tli_cli.ResultTliCatalogOpen
  (compiler-driver-clear-last-hydrated-archive-path!)
  (tli_cli.tli-open-catalog-for-session!
    load-state
    entry-path
    target
    stdlib-roots
    cfgs
    opt-level
    require-archive))

(define (compiler-driver-open-package-tli-catalogs-for-session!
  [load-state : (& compiler_load.CompilerLoadSessionState)]
  [entry-path : (& str)]
  [manifest-dir : (& str)]
  [deps : (& compiler_load.CompilerPkgDeps)]
  [target : target_cfg.CompilerTargetCfg]
  [stdlib-roots : (& svec.Vec)]
  [cfgs : sym_i64_env.SymI64Env]
  [opt-level : i64]
  [require-archive : bool]) : tli_cli.ResultTliCatalogOpen
  (match (compiler-driver-open-tli-catalog-for-session!
    load-state
    entry-path
    target
    stdlib-roots
    cfgs
    opt-level
    require-archive)
    [(Err msg) (tli_cli.ResultTliCatalogOpen.Err msg)]
    [(Ok)
      (tli_cli.tli-open-transitive-package-deps-for-session!
        load-state
        manifest-dir
        deps
        target
        cfgs
        require-archive)]))

(define compiler-driver-last-hydrated-startup-symbols-state : (__tl_dyn-array
    String)
  (__tl_make-array String 0))

(define (compiler-driver-copy-string-array [src : (& (__tl_dyn-array String))]) : (__tl_dyn-array
    String)
  (let
    [n : i64 (array-length (deref src))]
    [out : (__tl_dyn-array String) (__tl_make-array String n)]
    (for [i (iterator.range 0 n)]
      (set! (array-ref out i) (string.copy (& (array-ref (deref src) i)))))
    out))

(define (compiler-driver-apply-cached-tli-to-backend!
  [backend-state : be_state.CompilerBackendState]) : unit
  (when
    (> (array-length compiler-driver-last-hydrated-archive-paths-state) 0)
    (be_state.compiler-backend-state-set-archive-runtime! backend-state true)
    (be_state.compiler-backend-state-set-startup-init-symbols!
      backend-state
      (compiler-driver-copy-string-array
        (& compiler-driver-last-hydrated-startup-symbols-state)))))

(define (compiler-driver-apply-tli-hydrated-backend-state!
  [load-state : (& compiler_load.CompilerLoadSessionState)]
  [backend-state : be_state.CompilerBackendState]) : unit
  (if (compiler_load.compiler-load-session-state-tli-hydrated-any? load-state)
    (let
      [archives : (__tl_dyn-array String)
        (compiler_load.compiler-load-session-state-tli-archive-paths load-state)]
      [startup : (__tl_dyn-array String)
        (compiler_load.compiler-load-session-state-tli-startup-symbols
          load-state)]
      (be_state.compiler-backend-state-set-archive-runtime! backend-state true)
      (be_state.compiler-backend-state-set-startup-init-symbols!
        backend-state
        (compiler-driver-copy-string-array (& startup)))
      (set!
        compiler-driver-last-hydrated-archive-path-state
        (if (> (array-length archives) 0)
          (string.copy (& (array-ref archives (- (array-length archives) 1))))
          ""))
      (set! compiler-driver-last-hydrated-archive-paths-state archives)
      (set! compiler-driver-last-hydrated-startup-symbols-state startup)
      (set!
        compiler-driver-last-hydrated-stdlib-state
        (compiler_load.compiler-load-session-state-tli-stdlib-hydrated?
          load-state)))
    (begin
      ;; A batch reuses one backend state, so a source-stdlib entry must not
      ;; inherit the archive runtime of a prebuilt-stdlib entry before it.
      (be_state.compiler-backend-state-set-archive-runtime! backend-state false)
      (be_state.compiler-backend-state-set-startup-init-symbols!
        backend-state
        (__tl_make-array String 0))
      (set!
        compiler-driver-last-hydrated-startup-symbols-state
        (__tl_make-array String 0))
      (compiler-driver-clear-last-hydrated-archive-path!))))

(define (compiler-driver-finish-tli-hydrated-serial-session!) : unit
  (let
    [load-state : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-serial-test-session-state)]
    (if (compiler_load.compiler-load-session-state-tli-hydrated-any?
      (& load-state))
      (let
        [archives : (__tl_dyn-array String)
          (compiler_load.compiler-load-session-state-tli-archive-paths
            (& load-state))]
        [startup : (__tl_dyn-array String)
          (compiler_load.compiler-load-session-state-tli-startup-symbols
            (& load-state))]
        (set!
          compiler-driver-last-hydrated-archive-path-state
          (if (> (array-length archives) 0)
            (string.copy (& (array-ref archives (- (array-length archives) 1))))
            ""))
        (set! compiler-driver-last-hydrated-archive-paths-state archives)
        (set! compiler-driver-last-hydrated-startup-symbols-state startup)
        (set!
          compiler-driver-last-hydrated-stdlib-state
          (compiler_load.compiler-load-session-state-tli-stdlib-hydrated?
            (& load-state))))
      (begin
        (set!
          compiler-driver-last-hydrated-startup-symbols-state
          (__tl_make-array String 0))
        (compiler-driver-clear-last-hydrated-archive-path!)))
    (compiler_load.compiler-load-session-state-tli-release! (& load-state))
    (compiler_typecheck_core.tc-job-state-set-tli-facts-ptr!
      (compiler_typecheck_core.tc-serial-job-state)
      0)))

(define compiler-driver-pending-external-summaries : (__tl_dyn-array
    compiler_optimize.OptExternalSummaries)
  (__tl_make-array (compiler_optimize.opt-external-summaries-empty)))
(define compiler-driver-pending-external-summaries-present? : bool
  false)
(define compiler-driver-pending-startup-plan : (__tl_dyn-array
    tli_compact_ir.TliStartupInitPlan)
  (__tl_make-array (tli_compact_ir.tli-startup-init-plan-empty)))
(define compiler-driver-pending-startup-plan-present? : bool
  false)

;; Clear only presence flags so child-arena release paths never install a
;; child-arena-allocated empty struct into module-level globals.
(define (compiler-driver-clear-pending-external-summaries!) : unit
  (set! compiler-driver-pending-external-summaries-present? false)
  (set! compiler-driver-pending-startup-plan-present? false))

(define (compiler-driver-take-pending-startup-plan!) : tli_compact_ir.TliStartupInitPlan
  (if (not compiler-driver-pending-startup-plan-present?)
    (tli_compact_ir.tli-startup-init-plan-empty)
    (let
      [icount : i64
        (array-length
          (array-ref compiler-driver-pending-startup-plan 0).init-symbols)]
      [dcount : i64
        (array-length (array-ref compiler-driver-pending-startup-plan 0).deps)]
      [syms : (__tl_dyn-array String) (__tl_make-array String icount)]
      [deps : (__tl_dyn-array tli_compact_ir.TliStartupInitDep)
        (__tl_make-array tli_compact_ir.TliStartupInitDep dcount)]
      (for [i (iterator.range 0 icount)]
        (set!
          (array-ref syms i)
          (string.copy
            (&
              (array-ref
                (array-ref compiler-driver-pending-startup-plan 0).init-symbols
                i)))))
      (for [di (iterator.range 0 dcount)]
        (let
          [kn : i64
            (array-length
              (array-ref
                (array-ref compiler-driver-pending-startup-plan 0).deps
                di).init-indices)]
          [icopy : (__tl_dyn-array i64) (__tl_make-array i64 kn)]
          (for [k (iterator.range 0 kn)]
            (set!
              (array-ref icopy k)
              (array-ref
                (array-ref
                  (array-ref compiler-driver-pending-startup-plan 0).deps
                  di).init-indices
                k)))
          (set!
            (array-ref deps di)
            (tli_compact_ir.TliStartupInitDep
              (array-ref
                (array-ref compiler-driver-pending-startup-plan 0).deps
                di).sym-id
              icopy))))
      (set! compiler-driver-pending-startup-plan-present? false)
      (tli_compact_ir.TliStartupInitPlan syms deps))))

(define (compiler-driver-take-pending-external-summaries!) : compiler_optimize.OptExternalSummaries
  (if (not compiler-driver-pending-external-summaries-present?)
    (compiler_optimize.opt-external-summaries-empty)
    (let
      [n : i64
        (array-length
          (array-ref compiler-driver-pending-external-summaries 0).entries)]
      [out : (__tl_dyn-array compiler_optimize.OptExternalFnSummary)
        (__tl_make-array compiler_optimize.OptExternalFnSummary n)]
      (for [i (iterator.range 0 n)]
        (let
          [gn : i64
            (array-length
              (array-ref
                (array-ref compiler-driver-pending-external-summaries 0).entries
                i).global-write-ids)]
          [gcopy : (__tl_dyn-array i64) (__tl_make-array i64 gn)]
          (for [gi (iterator.range 0 gn)]
            (set!
              (array-ref gcopy gi)
              (array-ref
                (array-ref
                  (array-ref compiler-driver-pending-external-summaries 0).entries
                  i).global-write-ids
                gi)))
          (set!
            (array-ref out i)
            (compiler_optimize.OptExternalFnSummary
              (array-ref
                (array-ref compiler-driver-pending-external-summaries 0).entries
                i).link-id
              (array-ref
                (array-ref compiler-driver-pending-external-summaries 0).entries
                i).effect-flags
              (array-ref
                (array-ref compiler-driver-pending-external-summaries 0).entries
                i).call-memory
              (array-ref
                (array-ref compiler-driver-pending-external-summaries 0).entries
                i).call-clean
              (array-ref
                (array-ref compiler-driver-pending-external-summaries 0).entries
                i).return-alias
              gcopy))))
      (set! compiler-driver-pending-external-summaries-present? false)
      (compiler_optimize.OptExternalSummaries out))))

(define (compiler-driver-hydrate-tli-compact-ir!
  [load-state : (& compiler_load.CompilerLoadSessionState)]
  [pools : compiler_ast_types.AstNodePoolContext]
  [program : compiler_ir_types.CompilerIrProgram]
  [opt-level : i64]) : compiler_ir_types.CompilerIrProgram
  (compiler-driver-clear-pending-external-summaries!)
  (let
    [cat-ptr : i64
      (compiler_load.compiler-load-session-state-tli-catalog-ptr load-state)]
    [facts-ptr : i64
      (compiler_load.compiler-load-session-state-tli-facts-ptr load-state)]
    (if (or (= cat-ptr 0) (= facts-ptr 0) (= opt-level 0))
      program
      (let
        [hydrated : tli_compact_ir.TliHydratedCompactProgram
          (tli_compact_ir.tli-hydrate-compact-ir-from-ptrs!
            cat-ptr
            facts-ptr
            pools
            program
            opt-level)]
        (set!
          (array-ref compiler-driver-pending-external-summaries 0)
          hydrated.external-summaries)
        (set! compiler-driver-pending-external-summaries-present? true)
        (set!
          (array-ref compiler-driver-pending-startup-plan 0)
          hydrated.startup-plan)
        (set! compiler-driver-pending-startup-plan-present? true)
        hydrated.program))))

(define (compiler-driver-finish-tli-hydrated-session!
  [state : (& state CompilerDriverState)]) : unit
  ;; Lowering is the last TLI consumer. Copy the backend's archive facts into
  ;; the caller-owned arena that is current here, then retire the catalog and
  ;; drop the typecheck job's pointer into it.
  (compiler-driver-apply-tli-hydrated-backend-state!
    (& state.load-session)
    (compiler-driver-state-backend state))
  (compiler_load.compiler-load-session-state-tli-release!
    (& state.load-session))
  (compiler_typecheck_core.tc-job-state-set-tli-facts-ptr!
    (compiler-driver-state-typecheck state)
    0))

(define (compiler-driver-reset-file-state!) : unit
  ;; Compatibility reset for serial standalone helpers. Driver-state callers
  ;; install their active state before this and capture it again afterward.
  (compiler_load.compiler-load-default-session-use!)
  (compiler_load.compiler-load-tli-release!)
  (compiler-driver-clear-last-hydrated-archive-path!)
  (compiler-driver-clear-pending-external-summaries!)
  (compiler_load.compiler-load-session-reset-pools!)
  (compiler_load.compiler-load-session-reset-interns!)
  (compiler_typecheck_core.compiler-typecheck-reset-intern-owned-state!)
  (cbi.compiler-builtin-reset!)
  (compiler_ctfe.ctfe-builtin-reset!)
  (compiler_typecheck_core.compiler-typecheck-reset-file-state!)
  ;; Lowered results and driver jobs retain their own arena authority.
  (compiler_lower.lower-reset-file-state!))

(define (compiler-driver-reset-analysis-state!) : unit
  (cbi.compiler-builtin-reset!)
  (compiler_ctfe.ctfe-builtin-reset!)
  (compiler_typecheck_core.compiler-typecheck-reset-file-state!)
  (compiler_lower.lower-reset-file-state!))

(define (compiler-driver-state-reset-file-state! [state : CompilerDriverState]) : unit
  (compiler_load.compiler-load-session-state-tli-release!
    (& state.load-session))
  (compiler-driver-clear-last-hydrated-archive-path!)
  (compiler-driver-clear-pending-external-summaries!)
  (compiler-driver-state-apply-session-flags!
    (owned_view.compiler-owned-shared-view state))
  (compiler-driver-state-reset-owned-pool-arena-if-uncached!
    (owned_view.compiler-owned-shared-view state))
  (compiler-driver-state-reset-owned-intern-arena-if-uncached! (&mut state))
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler-driver-state-pool-context state)]
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
      (compiler-driver-state-typecheck state))
    (compiler_lower.lower-reset-file-state!)
    (compiler-driver-state-reset-lower!
      (owned_view.compiler-owned-shared-view state))
    ;; Drop the previous entry's lowerer arenas. At opt level 0
    ;; the escaped IR stays alive until the next file reset.
    (compiler-driver-state-release-lower-arenas! state)))

;; Post-emission batch cleanup. This runs while the caller-owned entry scratch
;; arena is still live, so it performs the same cache/intern/lower teardown as a
;; full file reset but leaves only a one-slot pool context behind. The next
;; entry's normal reset grows a fresh load pool after the old scratch chain is
;; gone instead of keeping a full-size replacement live between entries.
(define (compiler-driver-state-release-file-state!
  [state : CompilerDriverState]) : unit
  (compiler_load.compiler-load-session-state-tli-release!
    (& state.load-session))
  (compiler-driver-clear-pending-external-summaries!)
  (compiler-driver-state-apply-session-flags!
    (owned_view.compiler-owned-shared-view state))
  (compiler-driver-state-release-owned-pool-arena-if-uncached!
    (owned_view.compiler-owned-shared-view state))
  (compiler-driver-state-reset-owned-intern-arena-if-uncached! (&mut state))
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler-driver-state-pool-context state)]
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
      (compiler-driver-state-typecheck state))
    (compiler_typecheck_core.tc-entry-hidden-names-release!)
    (compiler_lower.lower-reset-file-state!)
    (compiler-driver-state-reset-lower!
      (owned_view.compiler-owned-shared-view state))
    (compiler-driver-state-release-lower-arenas! state)))

(cfg
  compile-profile
  (define (compiler-driver-state-release-file-state-profiled!
    [state : CompilerDriverState]
    [ordinal : i64]) : unit
    (compiler-driver-state-apply-session-flags!
      (owned_view.compiler-owned-shared-view state))
    ;; Post-emission cleanup deliberately installs only the compact one-slot
    ;; compatibility context. The next entry prepares full load capacity
    ;; after this entry's scratch chain is gone.
    (compiler-driver-state-release-owned-pool-arena-if-uncached!
      (owned_view.compiler-owned-shared-view state))
    (compiler_load.compiler-load-session-state-tli-release!
      (& state.load-session))
    (compiler-driver-clear-pending-external-summaries!)
    (compiler-driver-batch-profile-mark!
      (compiler-driver-state-profile state)
      ordinal
      "owned-pool-release")
    (compiler-driver-state-reset-owned-intern-arena-if-uncached! (&mut state))
    (let
      [pools : compiler_ast_types.AstNodePoolContext
        (compiler-driver-state-pool-context state)]
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
      (compiler-driver-state-reset-builtins!
        (owned_view.compiler-owned-shared-view state))
      (compiler_typecheck_core.compiler-typecheck-reset-file-state-for-job!
        (compiler-driver-state-typecheck state))
      (compiler_typecheck_core.tc-entry-hidden-names-release!)
      (compiler-driver-batch-profile-mark!
        (compiler-driver-state-profile state)
        ordinal
        "intern-session-cleanup")
      (compiler_lower.lower-reset-file-state!)
      (compiler-driver-state-reset-lower!
        (owned_view.compiler-owned-shared-view state))
      (compiler-driver-state-release-lower-arenas!
        (owned_view.compiler-owned-shared-view state))
      (compiler-driver-batch-profile-mark!
        (compiler-driver-state-profile state)
        ordinal
        "lower-cleanup"))))

(cfg
  (any compile-profile test)
  (counters.defslots
    compiler-driver-profile-starts
    0
    (compiler-driver-profile-total-start-ms-metric)
    (compiler-driver-profile-total-start-total-metric)
    (compiler-driver-profile-total-start-live-metric)
    (compiler-driver-profile-phase-start-ms-metric)
    (compiler-driver-profile-phase-start-total-metric)
    (compiler-driver-profile-phase-start-live-metric)
    (compiler-driver-profile-phase-start-intern-render-metric)
    (compiler-driver-profile-prelude-source-pipeline-entries-metric)
    (compiler-driver-profile-prelude-hydrations-metric)
    (compiler-driver-batch-profile-start-ms-metric)
    (compiler-driver-batch-profile-start-total-metric)
    (compiler-driver-batch-profile-start-live-metric)
    (compiler-driver-batch-profile-best-peak-metric)
    (compiler-driver-batch-profile-first-live-metric)))

;; Job-owned load lifetime boundary starts (CompilerProfileState 350-360 and
;; 368-369). Slot 350 is incremented by compiler_load through this job's
;; explicit interner metrics address; the driver owns the remaining boundary
;; snapshots.
(cfg
  (any compile-profile test)
  (counters.defslots
    compiler-driver-load-profile-starts
    350
    (compiler-driver-load-profile-input-bytes-metric)
    (compiler-driver-load-profile-start-total-metric)
    (compiler-driver-load-profile-start-live-metric)
    (compiler-driver-load-profile-start-peak-metric)
    (compiler-driver-load-profile-token-start-metric)
    (compiler-driver-load-profile-origin-start-metric)
    (compiler-driver-load-profile-pool-base-start-metric)
    (compiler-driver-load-profile-expr-start-metric)
    (compiler-driver-load-profile-type-start-metric)
    (compiler-driver-load-profile-surface-start-metric)
    (compiler-driver-load-profile-intern-start-metric)))

(cfg
  (any compile-profile test)
  (counters.defslots
    compiler-driver-load-profile-enclosing
    368
    (compiler-driver-load-profile-enclosing-handle-metric)
    (compiler-driver-load-profile-enclosing-start-metric)))

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
        _state
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
  (define (compiler-driver-profile-lifetime-line
    [boundary : String]
    [owner : String]
    [lifetime : String]
    [cumulative-alloc : i64]
    [retained-live : i64]
    [peak-delta : i64]) : String
    (str_cat.str-cat
      "compile-profile-lifetime|"
      boundary
      "|"
      owner
      "|"
      lifetime
      (compiler-driver-profile-field cumulative-alloc)
      (compiler-driver-profile-field retained-live)
      (compiler-driver-profile-field peak-delta)
      "\n")))

(cfg
  compile-profile
  (define (compiler-driver-profile-arena-bytes [owner : i64]) : i64
    (allocation_profile.compiler-allocation-profile-arena-bump-bytes owner)))

(cfg
  compile-profile
  (define (compiler-driver-profile-owner-delta [owner : i64] [start : i64]) : i64
    (compiler-driver-profile-nonnegative
      (- (compiler-driver-profile-arena-bytes owner) start))))

(cfg
  compile-profile
  (define (compiler-driver-profile-origin-bytes [control : i64]) : i64
    (+
      (compiler-driver-profile-arena-bytes
        (compiler_load.compiler-load-reader-node-pool-arena-handle))
      (compiler-driver-profile-arena-bytes
        (compiler_parse_core.compiler-parse-origin-word
          (compiler_parse_core.compiler-parse-origin-storage control)
          0)))))

(cfg
  compile-profile
  (define compiler-driver-load-profile-cache-start-metric : i64
    379))
(cfg
  compile-profile
  (define compiler-driver-load-profile-tli-batch-start-metric : i64
    383))

(cfg
  compile-profile
  (define (compiler-driver-profile-embedded-cache-bytes) : i64
    (cfg
      embedded-stdlib-tlci
      (embedded_tlci.compiler-embedded-stdlib-tlci-cache-bytes)
      0)))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-load-lifetime!
    [state : profile_state.CompilerProfileState]
    [pools : compiler_ast_types.AstNodePoolContext]
    [surface-arena : i64]
    [parser-control : i64]) : unit
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-cache-start-metric
      (compiler-driver-profile-embedded-cache-bytes))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-input-bytes-metric
      0)
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-start-total-metric
      (profile.alloc-total))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-start-live-metric
      (profile.alloc-live))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-start-peak-metric
      (profile.compile-wide-peak-current))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-token-start-metric
      (compiler-driver-profile-arena-bytes
        (compiler_load.compiler-load-lex-token-buffer-arena-handle)))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-origin-start-metric
      (compiler-driver-profile-origin-bytes parser-control))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-pool-base-start-metric
      (compiler-driver-profile-arena-bytes
        (compiler_ast_types.ast-node-pool-context-base-arena pools)))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-expr-start-metric
      (compiler-driver-profile-arena-bytes
        (compiler_ast_types.ast-node-pool-context-expr-storage-arena pools)))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-type-start-metric
      (compiler-driver-profile-arena-bytes
        (compiler_ast_types.ast-node-pool-context-type-storage-arena pools)))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-surface-start-metric
      (compiler-driver-profile-arena-bytes surface-arena))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-tli-batch-start-metric
      (compiler-driver-profile-arena-bytes
        (tli_cli.tli-batch-cache-arena-handle)))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-intern-start-metric
      (compiler_typecheck_core.compiler-tc-intern-storage-bytes))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-enclosing-handle-metric
      (arena.tl_arena_current))
    (compiler-driver-profile-set!
      state
      compiler-driver-load-profile-enclosing-start-metric
      (compiler-driver-profile-arena-bytes (arena.tl_arena_current)))))

(cfg
  compile-profile
  (define (compiler-driver-profile-emit-load-lifetime!
    [state : profile_state.CompilerProfileState]
    [pools : compiler_ast_types.AstNodePoolContext]
    [surface-arena : i64]
    [tli-arenas : (__tl_dyn-array i64)]
    [boundary : String]
    [parser-control : i64]) : unit
    (let
      [cumulative-alloc : i64
        (-
          (profile.alloc-total)
          (compiler-driver-profile-value
            state
            compiler-driver-load-profile-start-total-metric))]
      [live-delta : i64
        (compiler-driver-profile-nonnegative
          (-
            (profile.alloc-live)
            (compiler-driver-profile-value
              state
              compiler-driver-load-profile-start-live-metric)))]
      [peak-delta : i64
        (compiler-driver-profile-nonnegative
          (-
            (profile.compile-wide-peak-current)
            (compiler-driver-profile-value
              state
              compiler-driver-load-profile-start-peak-metric)))]
      [input-bytes : i64
        (compiler-driver-profile-value
          state
          compiler-driver-load-profile-input-bytes-metric)]
      [tokens : i64
        (compiler-driver-profile-owner-delta
          (compiler_load.compiler-load-lex-token-buffer-arena-handle)
          (compiler-driver-profile-value
            state
            compiler-driver-load-profile-token-start-metric))]
      [origins : i64
        (compiler-driver-profile-nonnegative
          (-
            (compiler-driver-profile-origin-bytes parser-control)
            (compiler-driver-profile-value
              state
              compiler-driver-load-profile-origin-start-metric)))]
      [pool-base : i64
        (compiler-driver-profile-owner-delta
          (compiler_ast_types.ast-node-pool-context-base-arena pools)
          (compiler-driver-profile-value
            state
            compiler-driver-load-profile-pool-base-start-metric))]
      [expr-pool : i64
        (compiler-driver-profile-owner-delta
          (compiler_ast_types.ast-node-pool-context-expr-storage-arena pools)
          (compiler-driver-profile-value
            state
            compiler-driver-load-profile-expr-start-metric))]
      [type-pool : i64
        (compiler-driver-profile-owner-delta
          (compiler_ast_types.ast-node-pool-context-type-storage-arena pools)
          (compiler-driver-profile-value
            state
            compiler-driver-load-profile-type-start-metric))]
      [tli-bytes : i64
        (let
          [sum : i64
            (compiler-driver-profile-owner-delta
              (tli_cli.tli-batch-cache-arena-handle)
              (compiler-driver-profile-value
                state
                compiler-driver-load-profile-tli-batch-start-metric))]
          (for [i (iterator.range 0 (array-length tli-arenas))]
            (let
              [h : i64 (array-ref tli-arenas i)]
              (when (> h 0) (+= sum (compiler-driver-profile-owner-delta h 0)))))
          sum)]
      [surface : i64
        (+
          (compiler-driver-profile-owner-delta
            surface-arena
            (compiler-driver-profile-value
              state
              compiler-driver-load-profile-surface-start-metric))
          tli-bytes)]
      [interns : i64
        (compiler-driver-profile-nonnegative
          (-
            (compiler_typecheck_core.compiler-tc-intern-storage-bytes)
            (compiler-driver-profile-value
              state
              compiler-driver-load-profile-intern-start-metric)))]
      [enclosing-handle : i64
        (compiler-driver-profile-value
          state
          compiler-driver-load-profile-enclosing-handle-metric)]
      [enclosing-is-tli : bool
        (let
          [batch-tli : i64 (tli_cli.tli-batch-cache-arena-handle)]
          [hit : bool (and (> batch-tli 0) (= enclosing-handle batch-tli))]
          (for [i (iterator.range 0 (array-length tli-arenas))]
            (when
              (and
                (> (array-ref tli-arenas i) 0)
                (= enclosing-handle (array-ref tli-arenas i)))
              (set! hit true)))
          hit)]
      [enclosing : i64
        (if (or
          (=
            enclosing-handle
            (compiler_ast_types.ast-node-pool-context-base-arena pools))
          (=
            enclosing-handle
            (compiler_ast_types.ast-node-pool-context-expr-storage-arena pools))
          (=
            enclosing-handle
            (compiler_ast_types.ast-node-pool-context-type-storage-arena pools))
          (= enclosing-handle surface-arena)
          enclosing-is-tli
          (= enclosing-handle (ci.intern-persistent-arena-handle))
          (= enclosing-handle (ci.intern-structural-records-arena-handle))
          (= enclosing-handle (ci.intern-structural-map-arena-handle))
          (= enclosing-handle (ci.intern-expansion-arena-handle)))
          0
          (compiler-driver-profile-owner-delta
            enclosing-handle
            (compiler-driver-profile-value
              state
              compiler-driver-load-profile-enclosing-start-metric)))]
      [embedded-cache : i64
        (-
          (compiler-driver-profile-embedded-cache-bytes)
          (compiler-driver-profile-value
            state
            compiler-driver-load-profile-cache-start-metric))]
      [named : i64
        (+
          embedded-cache
          enclosing
          (+
            tokens
            (+
              origins
              (+ pool-base (+ expr-pool (+ type-pool (+ surface interns)))))))]
      [remainder : i64 (- live-delta named)]
      (with-scratch
        (io.print-error
          (compiler-driver-profile-lifetime-line
            (owned_view.compiler-owned-shared-view boundary)
            "total"
            "boundary-total"
            cumulative-alloc
            live-delta
            peak-delta))
        (io.print-error
          (compiler-driver-profile-lifetime-line
            (owned_view.compiler-owned-shared-view boundary)
            "input-bytes"
            "payload-detail"
            cumulative-alloc
            input-bytes
            peak-delta))
        (io.print-error
          (compiler-driver-profile-lifetime-line
            (owned_view.compiler-owned-shared-view boundary)
            "frontend-read-parse"
            "transfer"
            cumulative-alloc
            enclosing
            peak-delta))
        (io.print-error
          (compiler-driver-profile-lifetime-line
            (owned_view.compiler-owned-shared-view boundary)
            "token-storage"
            "scan-scratch"
            cumulative-alloc
            tokens
            peak-delta))
        (io.print-error
          (compiler-driver-profile-lifetime-line
            (owned_view.compiler-owned-shared-view boundary)
            "reader-origin-storage"
            "transfer"
            cumulative-alloc
            origins
            peak-delta))
        (io.print-error
          (compiler-driver-profile-lifetime-line
            (owned_view.compiler-owned-shared-view boundary)
            "parsed-source-base"
            "transfer"
            cumulative-alloc
            pool-base
            peak-delta))
        (io.print-error
          (compiler-driver-profile-lifetime-line
            (owned_view.compiler-owned-shared-view boundary)
            "parsed-expr-pool"
            "transfer"
            cumulative-alloc
            expr-pool
            peak-delta))
        (io.print-error
          (compiler-driver-profile-lifetime-line
            (owned_view.compiler-owned-shared-view boundary)
            "parsed-type-pool"
            "transfer"
            cumulative-alloc
            type-pool
            peak-delta))
        (io.print-error
          (compiler-driver-profile-lifetime-line
            (owned_view.compiler-owned-shared-view boundary)
            "loader-session-surface"
            "session"
            cumulative-alloc
            surface
            peak-delta))
        (io.print-error
          (compiler-driver-profile-lifetime-line
            (owned_view.compiler-owned-shared-view boundary)
            "intern-storage"
            "session"
            cumulative-alloc
            interns
            peak-delta))
        (io.print-error
          (compiler-driver-profile-lifetime-line
            (owned_view.compiler-owned-shared-view boundary)
            "embedded-tlci-cache"
            "process"
            cumulative-alloc
            embedded-cache
            peak-delta))
        (io.print-error
          (compiler-driver-profile-lifetime-line
            boundary
            "remainder"
            "unattributed"
            cumulative-alloc
            remainder
            peak-delta))))))

(cfg
  compile-profile
  (define (compiler-driver-batch-profile-print!
    [ordinal : i64]
    [marker : String]
    [elapsed-ms : i64]
    [alloc-delta : i64]
    [live-delta : i64]
    [peak-delta : i64]
    [live-bytes : i64]
    [baseline-delta : i64]) : unit
    ;; Entry-start and steady rows run in the batch's long-lived arena.
    ;; Reclaim each row's formatting buffers as soon as it is written.
    (let
      [mark : arena.ArenaMark (arena.mark)]
      (io.print-error
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
          "\n"))
      (unsafe
        (arena.rewind mark)))))

(cfg
  compile-profile
  (define (compiler-driver-batch-profile-reset-baseline!
    [state : profile_state.CompilerProfileState]) : unit
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
    (profile.alloc-reset-peak)))

(cfg
  compile-profile
  (define (compiler-driver-batch-profile-start-entry!
    [state : profile_state.CompilerProfileState]
    [ordinal : i64]) : unit
    (let
      [live-bytes : i64 (profile.alloc-live)]
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
      (compiler-driver-batch-profile-print!
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
            compiler-driver-batch-profile-first-live-metric))))))

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
      (compiler-driver-batch-profile-print!
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
            compiler-driver-batch-profile-first-live-metric)))
      (compiler-driver-profile-set!
        state
        compiler-driver-batch-profile-best-peak-metric
        0)
      (compiler-driver-batch-profile-reset-baseline! state))))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-phase
    [state : profile_state.CompilerProfileState]) : unit
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
      compiler-driver-profile-phase-start-intern-render-metric
      (ci.intern-profile-render-value
        (compiler-driver-profile-intern-metrics-address state)))
    (profile.alloc-reset-peak)))

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
      [end-intern-render : i64
        (ci.intern-profile-render-value intern-metrics-address)]
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
            (owned_view.compiler-owned-shared-view phase)
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
            (str_cat.str-cat
              "compile-profile-detail|intern.phase.render|"
              (owned_view.compiler-owned-shared-view phase)
              "|"
              (string.int->string
                (-
                  end-intern-render
                  (compiler-driver-profile-value
                    state
                    compiler-driver-profile-phase-start-intern-render-metric)))
              "\n")))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-total
    [state : profile_state.CompilerProfileState]) : unit
    (begin
      (compiler-driver-profile-reset-prelude! state)
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
      (ci.intern-profile-reset!
        (compiler-driver-profile-intern-metrics-address state))
      (cfg
        compile-profile-summary
        (begin
          (compiler_optimize.compiler-opt-profile-summary-reset! state)
          (be_state.compiler-backend-profile-summary-reset! state))
        unit)
      (io.print-error
        "compile-profile|phase|elapsed_ms|alloc_delta_bytes|live_delta_bytes|peak_live_delta_bytes\n")
      (io.print-error
        "compile-profile-lifetime|boundary|owner|lifetime|cumulative_alloc_bytes|retained_live_bytes|peak_delta_bytes\n")
      (cfg
        compile-profile-summary
        (io.print-error
          "compile-profile-summary|scope|kind|rank|name|elapsed_ms|calls\n")
        unit)
      (compiler-driver-profile-start-phase state))))

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
                state
                compiler-driver-profile-prelude-source-pipeline-entries-metric))
            "\n"))
        (io.print-error
          (str_cat.str-cat
            "compile-profile-detail|prelude.hydrations|"
            (string.int->string
              (compiler-driver-profile-value
                state
                compiler-driver-profile-prelude-hydrations-metric))
            "\n"))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-finish-total
    [state : profile_state.CompilerProfileState]) : unit
    (let
      [compile-wide-peak : i64 (profile.compile-wide-peak-finish!)]
      [intern-metrics-address : u64
        (compiler-driver-profile-intern-metrics-address state)]
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
      (ci.intern-profile-activity-emit! intern-metrics-address)
      (ci.intern-profile-storage-emit! intern-metrics-address))))

(define (compiler-driver-lower-mode-for-target
  [target : be_state.CompilerBackendTarget]
  [mode : be_state.CompilerBackendMode]) : compiler_lower.CompilerLowerMode
  (match mode
    [(Avx2)
      (match target
        [(Linux) (LinuxAvx2)]
        [(Windows) (WindowsAvx2)])]
    [(Avx512)
      (match target
        [(Linux) (LinuxAvx512)]
        [(Windows) (WindowsAvx512)])]
    [_
      (match target
        [(Linux) (LinuxScalar)]
        [(Windows) (WindowsScalar)])]))

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
  [target : be_state.CompilerBackendTarget]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (cbi.compiler-builtin-initialize-for-parse!)
  (let
    [target-cfgs : sym_i64_env.SymI64Env
      (match target
        [(Linux) (compiler-driver-enable-linux-cfgs cfgs)]
        [(Windows) (compiler-driver-enable-windows-cfgs cfgs)])]
    [backtrace-id : i64 (ci.intern "compiler-backtrace")]
    [public-cfgs : sym_i64_env.SymI64Env
      (cfg_core.compiler-cfg-remove-id target-cfgs backtrace-id)]
    (if (compiler_ir_types.compiler-debug-info-enabled?)
      (cfg_core.compiler-cfg-enable public-cfgs "compiler-backtrace")
      public-cfgs)))

(define (compiler-driver-state-target-cfgs
  [state : CompilerDriverState]
  [target : be_state.CompilerBackendTarget]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [target-cfgs : sym_i64_env.SymI64Env
      (match target
        [(Linux)
          (compiler-driver-enable-linux-cfgs-with-intern-state
            cfgs
            (&mut (array-ref state.intern-state 0)))]
        [(Windows)
          (compiler-driver-enable-windows-cfgs-with-intern-state
            cfgs
            (&mut (array-ref state.intern-state 0)))])]
    [backtrace-id : i64
      (ci.intern-compat-state-intern
        (&mut (array-ref state.intern-state 0))
        "compiler-backtrace")]
    [public-cfgs : sym_i64_env.SymI64Env
      (cfg_core.compiler-cfg-remove-id target-cfgs backtrace-id)]
    (if (compiler_ir_types.compiler-debug-info-enabled?)
      (cfg_core.compiler-cfg-enable-with-intern-state
        public-cfgs
        "compiler-backtrace"
        (&mut (array-ref state.intern-state 0)))
      public-cfgs)))

;; `mode` must be the backend mode the program was lowered for: SIMD lower
;; modes produce vector IR that only the matching backend mode can encode.
(define (compiler-driver-emit-lowered-with-level-and-mode
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [lower-state : compiler_lower.CompilerLowerState]) : ResultCompilerDriver
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    [backend-state : be_state.CompilerBackendState
      (be_state.compiler-backend-state-new-with-metrics
        (ci.intern-compat-state-capture-active)
        (profile_state.compiler-profile-state-metrics profile-state))]
    [_apply-tli : unit
      (compiler-driver-apply-cached-tli-to-backend! backend-state)]
    [result : ResultCompilerDriver
      (match (compiler-driver-emit-lowered
        (CompilerDriverOutputRoute.Assembly)
        (compiler_ast_types.ast-node-pool-reader-context-current)
        input-path
        program
        spans
        target
        has-target
        mode
        opt-level
        true
        false
        profile-state
        backend-state
        (compiler_typecheck_core.tc-serial-job-state)
        lower-state)
        [(Assembly output)
          (Ok
            output
            (compiler-driver-advisories-for-job
              (compiler_typecheck_core.tc-serial-job-state)))]
        [(Err diagnostic)
          (Err
            diagnostic
            (compiler-driver-advisories-for-job
              (compiler_typecheck_core.tc-serial-job-state)))]
        [_ (io.panic "compiler driver: unexpected emit result")])]
    (compiler_backend.compiler-backend-state-release-final-arenas!
      backend-state)
    result))

(define (compiler-driver-emit-lowered-with-level
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [opt-level : i64]
  [lower-state : compiler_lower.CompilerLowerState]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-with-level-and-mode
    input-path
    program
    spans
    target
    has-target
    (Scalar)
    opt-level
    lower-state))

;; The lowered IR functions live in a dedicated arena
;; owned by the lower job; at opt levels >= 1 the optimizer deep-clones every
;; surviving function out of it. Level 2 retires it at the end of the inline
;; walk, before the carrier handoff; this post-optimize cleanup also covers
;; level 1 and is idempotent. At level 0
;; the lowered program flows to the backend unchanged and stays alive.
(define (compiler-driver-release-lowered-ir!
  [opt-level : i64]
  [lower-state : compiler_lower.CompilerLowerState]) : unit
  (if (>= opt-level 1)
    (compiler_lower.compiler-lower-arena-state-release-ir!
      (& (compiler_lower.compiler-lower-state-arenas lower-state)))
    unit))

;; The optimizer receives the exact job's stable address, never an ambient
;; lower owner. Its callback runs only once the level-2 inline walk has placed
;; every surviving body in the optimizer-input arena.
(define (compiler-driver-retire-lowered-input! [owner-address : i64]) : unit
  (compiler-driver-release-lowered-ir!
    2
    (compiler_lower.compiler-lower-state-from-address owner-address)))

;; The level-2 inline walk has placed every original of lowered-IR chunk CHUNK
;; of this exact owner; release that chunk (#9059).
(define (compiler-driver-release-lowered-input-chunk!
  [owner-address : i64]
  [chunk : i64]) : unit
  (compiler_lower.compiler-lower-ir-chunk-release!
    (&
      (compiler_lower.compiler-lower-state-arenas
        (compiler_lower.compiler-lower-state-from-address owner-address)))
    chunk))

;; The lowered-IR chunk byte budget of a progressive level-2 lowering.
(define compiler-driver-lowered-ir-chunk-bytes : i64
  4194304)

;; The lowering request's chunk policy, set on the owner before each lowering:
;; full optimization retires lowered IR progressively and escapes bodies
;; into chunks. Levels 0 and 1 keep the whole-owner arena.
(define (compiler-driver-lower-state-configure-input!
  [lower-state : compiler_lower.CompilerLowerState]
  [opt-level : i64]) : unit
  (compiler_lower.compiler-lower-arena-state-set-ir-chunk-budget!
    (& (compiler_lower.compiler-lower-state-arenas lower-state))
    (if (opt_level.opt-level-full? opt-level)
      compiler-driver-lowered-ir-chunk-bytes
      0)))

;; The optimizer's authority over this exact lowered owner: whole retirement
;; after the walk and per-chunk release during it.
(define (compiler-driver-lowered-input-retirement
  [lower-state : compiler_lower.CompilerLowerState]) : compiler_optimize.OptInputRetirement
  (compiler_optimize.OptInputRetirement.Retire
    lower-state.address
    compiler-driver-retire-lowered-input!
    compiler-driver-release-lowered-input-chunk!))

;: The lowered owner's chunk bounds as plain lower-sequence positions, one more
;; than the chunk count; empty on the whole-owner path.
(define (compiler-driver-lowered-input-chunk-bounds
  [lower-state : compiler_lower.CompilerLowerState]) : (__tl_dyn-array i64)
  (let
    [arenas : compiler_lower.CompilerLowerArenaState
      (compiler_lower.compiler-lower-state-arenas lower-state)]
    [count : i64 (compiler_lower.compiler-lower-ir-chunk-count (& arenas))]
    [bounds : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (if (= count 0)
          0
          (+ count 1)))]
    [chunk : i64 0]
    (while (and (> count 0) (<= chunk count))
      (set!
        (array-ref bounds chunk)
        (compiler_lower.compiler-lower-ir-chunk-start (& arenas) chunk))
      (set! chunk (+ chunk 1)))
    bounds))

;; Once lowering has produced IR, optimizer/backend no longer consult the full
;; typecheck/macro CTFE caches. Drop them before the backend's large assembly
;; buffers are allocated, but retain the compact definition-site alias table:
;; package surface emission can still expand a dependent macro under this same
;; source-name owner. The lower scratch arena is function-local: escaped IR
;; lives outside it, so it can be released before optimize/backend instead of
;; overlapping with backend assembly buffers.
(define (compiler-driver-release-typecheck-caches-after-lower-for-job!
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [lower-state : compiler_lower.CompilerLowerState]) : unit
  (compiler_typecheck_core.compiler-typecheck-reset-file-state-preserving-lazy-imports-for-job!
    typecheck-state)
  (compiler_lower.compiler-lower-arena-state-release-scratch!
    (& (compiler_lower.compiler-lower-state-arenas lower-state))))

;; Package builds may run TLci, direct-object, and doctest passes after an
;; assembly emit while keeping the loaded AST alive. A full file-state reset
;; would invalidate those loaded pools, but the lowered IR has already been
;; consumed by the backend and can be dropped at any opt level.
(define (compiler-driver-release-lower-arenas-after-emit!
  [lower-state : compiler_lower.CompilerLowerState]) : unit
  (compiler_lower.compiler-lower-arena-state-release!
    (compiler_lower.compiler-lower-state-arenas lower-state)))

(define (compiler-driver-representation-index-for-backend
  [pools : compiler_ast_types.AstNodePoolContext]
  [program : (& compiler_ir_types.CompilerIrProgram)]
  [backend-state : be_state.CompilerBackendState]
  [typecheck-state : compiler_typecheck_core.TcJobState]) : compiler_ir_types.CompilerIrRepresentationIndex
  (let
    [interns : ci.InternCompatState
      (be_state.compiler-backend-state-intern backend-state)]
    [owner : arena.Arena
      (compiler_backend.compiler-backend-state-prepare-representation-arena!
        backend-state)]
    [representations : compiler_ir_types.CompilerIrRepresentationIndex
      (in-arena
        owner
        (compiler_ir_types.compiler-ir-representation-index-with-authority
          pools
          interns
          -1
          program
          (compiler_lower.lower-representation-index-from-layouts
            (compiler_ast_types.ast-node-pool-context-type-segment-bases pools)
            typecheck-state
            (compiler_ir_types.compiler-ir-representation-index-empty))))]
    (be_state.compiler-backend-state-set-representations-for-pools!
      backend-state
      (& pools)
      (owned_view.compiler-owned-shared-view representations))
    representations))

;; Object routes retain the input until eligibility chooses their consumer.
;; IR deliberately keeps its existing empty-index request (#9142).
(defenum CompilerDriverOutputRoute
  (Assembly)
  (Buffer)
  (Pic)
  (ObjectImage)
  (PackageRuntime)
  (Ir))

(defenum ResultCompilerDriverEmit
  (Assembly String)
  (Buffer text_buf.TextBuf)
  (Pic be_state.CompilerBackendPicOutput)
  (ObjectImage cobj.CompilerObjectImage)
  (PackageRuntime cobj.CompilerObjectImage String)
  ;; PackageRuntime's assembly fallback for an ineligible program.
  (Fallback String be_state.CompilerDirectObjectFallbackReason)
  ;; ObjectImage leaves an ineligible program to the caller's fallback.
  (Unavailable be_state.CompilerDirectObjectFallbackReason)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defenum CompilerDriverBackendProgram
  (Program
    compiler_ir_types.CompilerIrProgram
    compiler_ir_types.CompilerSourceSpans)
  (Exhausted))

(define (compiler-driver-optimize-lowered
  [pools : compiler_ast_types.AstNodePoolContext]
  [backend-state : be_state.CompilerBackendState]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [opt-level : i64]
  [profile-state : profile_state.CompilerProfileState]
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [lower-state : compiler_lower.CompilerLowerState]
  [representations : compiler_ir_types.CompilerIrRepresentationIndex]
  [route : CompilerDriverOutputRoute]) : compiler_optimize.CompilerOptimizedProgram
  (compiler-driver-release-typecheck-caches-after-lower-for-job!
    typecheck-state
    lower-state)
  (compiler-driver-retire-frontend-arena!)
  (let
    [backend? : bool
      (match route
        [(Ir) false]
        [_ true])]
    [_start : unit
      (cfg
        compile-profile
        (when backend? (compiler-driver-profile-start-phase profile-state))
        unit)]
    [result : compiler_optimize.CompilerOptimizedProgram
      (compiler_optimize.optimize-program
        (owned_view.compiler-owned-shared-view program)
        spans
        (compiler_optimize.OptimizeRequest
          pools
          (be_state.compiler-backend-state-intern backend-state)
          opt-level
          profile-state
          backend?
          representations
          (compiler-driver-lowered-input-retirement lower-state)
          (compiler-driver-lowered-input-chunk-bounds lower-state)
          (compiler-driver-take-pending-external-summaries!)
          false))]
    [startup-plan : tli_compact_ir.TliStartupInitPlan
      (compiler-driver-take-pending-startup-plan!)]
    (when
      (> (array-length startup-plan.init-symbols) 0)
      (match (& result)
        [(compiler_optimize.CompilerOptimizedProgram.Program opt-program _)
          (be_state.compiler-backend-state-set-startup-init-symbols!
            backend-state
            (tli_compact_ir.tli-filter-startup-init-symbols
              (& startup-plan)
              opt-program))]))
    (cfg
      compile-profile
      (when
        backend?
        (compiler-driver-profile-finish-phase profile-state "optimize")))
    (match route
      [(Buffer)
        (compiler-driver-allocation-profile-snapshot-for-job!
          typecheck-state
          "optimize"
          lower-state)]
      [_ unit])
    (match route
      [(ObjectImage) unit]
      [(PackageRuntime) unit]
      [_ (compiler-driver-release-lowered-ir! opt-level lower-state)])
    result))

;; Every backend route's lowered-to-optimize step: the type-pool checks around
;; the explicit-index optimizer, then the scalar-register policy. Releasing
;; the lowered IR is idempotent; after a late exhaustion it also covers the
;; object routes' retained input.
(define (compiler-driver-optimize-for-backend
  [route : CompilerDriverOutputRoute]
  [pools : compiler_ast_types.AstNodePoolContext]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [opt-level : i64]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : be_state.CompilerBackendState]
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [lower-state : compiler_lower.CompilerLowerState]) : CompilerDriverBackendProgram
  (when
    (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (return (Exhausted)))
  (let
    [representations : compiler_ir_types.CompilerIrRepresentationIndex
      (compiler-driver-representation-index-for-backend
        pools
        (& program)
        backend-state
        typecheck-state)]
    (match (compiler-driver-optimize-lowered
      pools
      backend-state
      program
      spans
      opt-level
      profile-state
      typecheck-state
      lower-state
      representations
      route)
      [(Program optimized optimized-spans)
        (when
          (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
          (compiler-driver-release-lowered-ir! opt-level lower-state)
          (return (Exhausted)))
        (be_state.compiler-backend-state-set-opt-level! backend-state opt-level)
        (be_state.compiler-backend-state-set-optimize-for-size!
          backend-state
          (opt_level.opt-level-size? opt-level))
        (Program optimized optimized-spans)])))

;; The object routes' eligibility gate. An ineligible ObjectImage program keeps
;; its lowered input for the caller's assembly fallback: at optimized levels
;; the release must happen only after object eligibility is established.
;; PackageRuntime emits that fallback itself and pairs an object image with
;; side assembly from a separate backend state.
(define (compiler-driver-emit-optimized-object
  [route : CompilerDriverOutputRoute]
  [pools : compiler_ast_types.AstNodePoolContext]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : be_state.CompilerBackendTarget]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : be_state.CompilerBackendState]
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [lower-state : compiler_lower.CompilerLowerState]) : ResultCompilerDriverEmit
  (match (compiler_backend.compiler-backend-object-program-eligibility-with-pools-and-profile-state
    backend-state
    pools
    (owned_view.compiler-owned-shared-view program)
    target
    profile-state)
    [(Unsupported category)
      (match route
        [(ObjectImage) (Unavailable category)]
        [_
          (compiler-driver-release-lowered-ir! opt-level lower-state)
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase profile-state))
          (let
            [result : ResultCompilerDriverEmit
              (match (compiler_backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                backend-state
                pools
                program
                target
                mode
                spans
                emit-entry
                crt-entry
                profile-state)
                [(Ok asm) (Fallback asm category)]
                [(Err diag) (Err diag)])]
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase profile-state "backend"))
            result)])]
    [(Eligible)
      (compiler-driver-release-lowered-ir! opt-level lower-state)
      (cfg compile-profile (compiler-driver-profile-start-phase profile-state))
      (match (compiler_backend.compiler-backend-emit-program-object-image-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
        backend-state
        pools
        (owned_view.compiler-owned-shared-view program)
        target
        mode
        (owned_view.compiler-owned-shared-view spans)
        emit-entry
        crt-entry
        profile-state)
        [(Ok image)
          (match route
            [(ObjectImage)
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase profile-state "backend"))
              (ObjectImage image)]
            [_
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase
                  profile-state
                  "backend.object-image"))
              (let
                [side-backend-state : be_state.CompilerBackendState
                  (be_state.compiler-backend-state-new-with-metrics
                    (ci.intern-compat-state-capture-active)
                    (profile_state.compiler-profile-state-metrics profile-state))]
                (be_state.compiler-backend-state-set-archive-runtime!
                  side-backend-state
                  (be_state.compiler-backend-state-archive-runtime?
                    backend-state))
                (be_state.compiler-backend-state-set-startup-init-symbols!
                  side-backend-state
                  (be_state.compiler-backend-state-startup-init-symbols
                    backend-state))
                (be_state.compiler-backend-state-set-advisory-sink!
                  side-backend-state
                  (compiler_typecheck_core.tc-job-state-advisory-sink
                    typecheck-state))
                (be_state.compiler-backend-state-set-opt-level!
                  side-backend-state
                  opt-level)
                (be_state.compiler-backend-state-set-optimize-for-size!
                  side-backend-state
                  (opt_level.opt-level-size? opt-level))
                (cfg
                  compile-profile
                  (compiler-driver-profile-start-phase profile-state))
                (let
                  [side-result : be_state.ResultCompilerBackend
                    (compiler_backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                      side-backend-state
                      pools
                      program
                      target
                      mode
                      spans
                      emit-entry
                      crt-entry
                      profile-state)]
                  (compiler_backend.compiler-backend-state-release-final-arenas!
                    side-backend-state)
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase
                      profile-state
                      "backend.side-assembly"))
                  (match side-result
                    [(Ok asm) (PackageRuntime image asm)]
                    [(Err diag) (Err diag)])))])]
        [(Err diag)
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase profile-state "backend"))
          (Err diag)])]))

(define (compiler-driver-emit-lowered
  [route : CompilerDriverOutputRoute]
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]
  [backend-state : be_state.CompilerBackendState]
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [lower-state : compiler_lower.CompilerLowerState]) : ResultCompilerDriverEmit
  (match (compiler-driver-optimize-for-backend
    route
    pools
    program
    spans
    opt-level
    profile-state
    backend-state
    typecheck-state
    lower-state)
    [(Exhausted)
      (Err (box (compiler-driver-ty-node-pool-exhausted-diagnostic input-path)))]
    [(Program optimized optimized-spans)
      (let
        [optimized : compiler_ir_types.CompilerIrProgram
          (if (be_state.compiler-backend-state-closed-executable? backend-state)
            (compiler_optimize.compiler-optimize-prune-orphan-initializers
              optimized)
            optimized)]
        [emit-target : be_state.CompilerBackendTarget
          (if has-target
            target
            (Linux))]
        [result : ResultCompilerDriverEmit
          (match route
            [(ObjectImage)
              (compiler-driver-emit-optimized-object
                route
                pools
                optimized
                optimized-spans
                emit-target
                mode
                opt-level
                emit-entry
                crt-entry
                profile-state
                backend-state
                typecheck-state
                lower-state)]
            [(PackageRuntime)
              (compiler-driver-emit-optimized-object
                route
                pools
                optimized
                optimized-spans
                emit-target
                mode
                opt-level
                emit-entry
                crt-entry
                profile-state
                backend-state
                typecheck-state
                lower-state)]
            [_
              (cfg
                compile-profile
                (compiler-driver-profile-start-phase profile-state))
              (let
                [assembly : ResultCompilerDriverEmit
                  (match route
                    [(Assembly)
                      (match (compiler_backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                        backend-state
                        pools
                        optimized
                        emit-target
                        mode
                        optimized-spans
                        emit-entry
                        crt-entry
                        profile-state)
                        [(Ok asm) (Assembly asm)]
                        [(Err diagnostic) (Err diagnostic)])]
                    [(Buffer)
                      (match (compiler_backend.compiler-backend-emit-program-target-with-mode-final-buffer-with-pools-and-crt-and-profile-state-backend-state
                        backend-state
                        pools
                        optimized
                        emit-target
                        mode
                        optimized-spans
                        emit-entry
                        crt-entry
                        profile-state)
                        [(Ok buf) (Buffer buf)]
                        [(Err diagnostic) (Err diagnostic)])]
                    [(Pic)
                      (match (compiler_backend.compiler-backend-emit-program-pic-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                        backend-state
                        pools
                        optimized
                        emit-target
                        mode
                        optimized-spans
                        emit-entry
                        crt-entry
                        profile-state)
                        [(Ok output) (Pic output)]
                        [(Err diagnostic) (Err diagnostic)])]
                    [_
                      (io.panic "compiler driver: invalid assembly emit route")])]
                (cfg
                  compile-profile
                  (compiler-driver-profile-finish-phase profile-state "backend"))
                (match route
                  [(Buffer)
                    (compiler-driver-allocation-profile-snapshot-for-job!
                      typecheck-state
                      "backend"
                      lower-state)
                    (compiler-driver-allocation-profile-backend-output-snapshot!
                      backend-state)]
                  [_ unit])
                assembly)])]
        (match result
          [(Err diagnostic)
            (Err
              (box
                (compiler_diagnostic.compiler-diagnostic-with-fallback-path
                  (deref diagnostic)
                  input-path)))]
          [_ result]))]))

(define (compiler-driver-object-result
  [result : ResultCompilerDriverEmit]
  [advisories : compiler_diagnostic.CompilerAdvisoryList]) : ResultCompilerDriverObject
  (match result
    [(ObjectImage image) (Ok image advisories)]
    [(Unavailable category) (Unavailable category advisories)]
    [(Err diagnostic) (Err diagnostic advisories)]
    [_ (io.panic "compiler driver: unexpected emit result")]))

(define (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt-and-profile-state
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]
  [lower-state : compiler_lower.CompilerLowerState]) : ResultCompilerDriverObject
  (let
    [backend-state : be_state.CompilerBackendState
      (be_state.compiler-backend-state-new-with-metrics
        (ci.intern-compat-state-capture-active)
        (profile_state.compiler-profile-state-metrics profile-state))]
    [_apply-tli : unit
      (compiler-driver-apply-cached-tli-to-backend! backend-state)]
    [emitted : ResultCompilerDriverEmit
      (compiler-driver-emit-lowered
        (CompilerDriverOutputRoute.ObjectImage)
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
        profile-state
        backend-state
        (compiler_typecheck_core.tc-serial-job-state)
        lower-state)]
    [result : ResultCompilerDriverObject
      (compiler-driver-object-result
        emitted
        (compiler-driver-advisories-for-job
          (compiler_typecheck_core.tc-serial-job-state)))]
    (compiler_backend.compiler-backend-state-release-final-arenas!
      backend-state)
    result))

;; Serial/test compatibility adapters. Driver-owned compile paths carry the
;; state from ResultCompilerDriverLowered into the explicit-state emit above.
(define (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt
  [pools : compiler_ast_types.AstNodePoolContext]
  [input-path : String]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [lower-state : compiler_lower.CompilerLowerState]) : ResultCompilerDriverObject
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
    (profile_state.compiler-profile-state-new)
    lower-state))

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
      (set! compiler-driver-pending-frontend-return-arena 0)
      (compiler-driver-restore-arena-owner-current! return-arena))))

;; Lowering can report an error while the checked-pool handoff owns a temporary
;; macro frontend that abort must retire. Deep-copy the diagnostic into the
;; compile state's retained surface before that transition runs; the result can
;; then cross the load/lower boundary without borrowing the retiring arena.
(define (compiler-driver-diagnostic-copy-to-state-surface
  [state : CompilerDriverState]
  [diag : (Box compiler_diagnostic.CompilerDiagnostic)]) : (Box
    compiler_diagnostic.CompilerDiagnostic)
  (in-arena
    (unsafe
      (arena.Arena (compiler-driver-state-surface-arena state)))
    (box (compiler_diagnostic.compiler-diagnostic-copy (deref diag)))))

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
        (set! compiler-driver-pending-retired-frontend-arena 0)
        (arena.tl_arena_destroy retire-arena)
        (arena.tl_arena_set retained-arena)))))

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
      ;; Clear globals at the outer emit boundary, after the load/lower call
      ;; has returned and no active frame can still hold their arena values.
      (compiler-driver-state-clear-pool-backed-caches!)
      (compiler_lower.lower-reset-file-state!)
      (unsafe
        (set! compiler-driver-pending-retired-source-arena 0)
        (set! compiler-driver-pending-retired-source-expr-storage-arena 0)
        (set! compiler-driver-pending-retired-source-type-storage-arena 0)
        (compiler_ast_types.ast-node-pool-storage-arenas-destroy!
          retire-expr-storage-arena
          retire-type-storage-arena
          retire-arena)
        (arena.tl_arena_destroy retire-arena)
        (arena.tl_arena_set retained-arena)))))

(cfg
  compile-profile
  (define (compiler-driver-route-retain-profile?
    [route : CompilerDriverOutputRoute]) : bool
    (match route
      [(Assembly) true]
      [(Buffer) true]
      [_ false])))

(defenum CompilerDriverEmitted
  (Emitted ResultCompilerDriverEmit compiler_diagnostic.CompilerAdvisoryList))

;; One lowered result's emit: keep the program shells retirement needs,
;; retire the lowered source arena around the route's emit body, then drop
;; the lower arenas. Only Assembly and Buffer record the retain phases, and
;; Buffer leaves its lower arenas to the caller.
(define (compiler-driver-lowered-result-set-archive-runtime!
  [lowered : (& ResultCompilerDriverLowered)]
  [enabled : bool]) : unit
  (match lowered
    [(Ok _ _ _ _ backend-state _ _)
      (be_state.compiler-backend-state-set-archive-runtime!
        backend-state
        enabled)]
    [_ unit]))

(define (compiler-driver-emit-lowered-result
  [route : CompilerDriverOutputRoute]
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [closed-executable : bool]) : CompilerDriverEmitted
  (match lowered
    [(Ok
        program
        spans
        pools
        profile-state
        backend-state
        typecheck-state
        lower-state)
      (let
        [_profile-program-start : unit
          (cfg
            compile-profile
            (when
              (compiler-driver-route-retain-profile? route)
              (compiler-driver-profile-start-phase
                (owned_view.compiler-owned-shared-view profile-state)))
            unit)]
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              pools
              (& program))
            program)]
        [_profile-program-finish : unit
          (cfg
            compile-profile
            (when
              (compiler-driver-route-retain-profile? route)
              (compiler-driver-profile-finish-phase
                (owned_view.compiler-owned-shared-view profile-state)
                "retain.program"))
            unit)]
        [_profile-spans-start : unit
          (cfg
            compile-profile
            (when
              (compiler-driver-route-retain-profile? route)
              (compiler-driver-profile-start-phase
                (owned_view.compiler-owned-shared-view profile-state)))
            unit)]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone-compiler-source-spans (& spans))
            spans)]
        [_profile-spans-finish : unit
          (cfg
            compile-profile
            (when
              (compiler-driver-route-retain-profile? route)
              (compiler-driver-profile-finish-phase
                (owned_view.compiler-owned-shared-view profile-state)
                "retain.spans"))
            unit)]
        [out : CompilerDriverEmitted
          (begin
            (compiler_ast_types.ast-node-pool-reader-use! pools)
            (be_state.compiler-backend-state-set-closed-executable!
              backend-state
              (and
                closed-executable
                (opt_level.opt-level-full? opt-level)
                emit-entry
                (not crt-entry)
                (not (compiler_ir_types.compiler-debug-info-enabled?))))
            (cfg
              compile-profile
              (when
                (compiler-driver-route-retain-profile? route)
                (compiler-driver-profile-start-phase
                  (owned_view.compiler-owned-shared-view profile-state))))
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (cfg
              compile-profile
              (when
                (compiler-driver-route-retain-profile? route)
                (compiler-driver-profile-finish-phase
                  (owned_view.compiler-owned-shared-view profile-state)
                  "retain.release")))
            (let
              [result : ResultCompilerDriverEmit
                (compiler-driver-emit-lowered
                  route
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
                  typecheck-state
                  lower-state)]
              (Emitted
                result
                (compiler-driver-advisories-for-job typecheck-state))))]
        (if (= opt-level 0)
          (compiler-driver-retire-lowered-source-arena!)
          unit)
        (match route
          [(Buffer) unit]
          [_ (compiler-driver-release-lower-arenas-after-emit! lower-state)])
        (compiler_ast_types.ast-node-pool-reader-clear!)
        (compiler-driver-restore-frontend-return-arena!)
        out)]
    [(Err diag advisories)
      (compiler-driver-restore-frontend-return-arena!)
      (Emitted (Err diag) advisories)]))

(define (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [closed-executable : bool]) : ResultCompilerDriver
  (match (compiler-driver-emit-lowered-result
    (CompilerDriverOutputRoute.Assembly)
    input-path
    lowered
    target
    has-target
    mode
    opt-level
    emit-entry
    crt-entry
    closed-executable)
    [(Emitted (Assembly output) advisories) (Ok output advisories)]
    [(Emitted (Err diagnostic) advisories) (Err diagnostic advisories)]
    [_ (io.panic "compiler driver: unexpected emit result")]))

(define (compiler-driver-emit-lowered-result-buffer-with-level-mode-and-entry
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [closed-executable : bool]) : ResultCompilerDriverBuffer
  (match (compiler-driver-emit-lowered-result
    (CompilerDriverOutputRoute.Buffer)
    input-path
    lowered
    target
    has-target
    mode
    opt-level
    emit-entry
    false
    closed-executable)
    [(Emitted (Buffer output) advisories) (Ok output advisories)]
    [(Emitted (Err diagnostic) advisories) (Err diagnostic advisories)]
    [_ (io.panic "compiler driver: unexpected emit result")]))

(define (compiler-driver-emit-lowered-result-object-image-with-level-mode-entry-and-crt
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]
  [closed-executable : bool]) : ResultCompilerDriverObject
  (match (compiler-driver-emit-lowered-result
    (CompilerDriverOutputRoute.ObjectImage)
    input-path
    lowered
    target
    has-target
    mode
    opt-level
    emit-entry
    crt-entry
    closed-executable)
    [(Emitted result advisories)
      (compiler-driver-object-result result advisories)]))

(define (compiler-driver-emit-lowered-result-package-runtime-with-level-mode-entry-and-crt
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : be_state.CompilerBackendTarget]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverPackageRuntime
  (match (compiler-driver-emit-lowered-result
    (CompilerDriverOutputRoute.PackageRuntime)
    input-path
    lowered
    target
    true
    mode
    opt-level
    emit-entry
    crt-entry
    false)
    [(Emitted (PackageRuntime image asm) advisories)
      (Object image asm advisories)]
    [(Emitted (Fallback asm category) advisories)
      (Assembly asm category advisories)]
    [(Emitted (Err diagnostic) advisories) (Err diagnostic advisories)]
    [_ (io.panic "compiler driver: unexpected emit result")]))

(define (compiler-driver-emit-lowered-result-pic-with-level-mode-entry-and-crt
  [input-path : String]
  [lowered : ResultCompilerDriverLowered]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [mode : be_state.CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriverPic
  (match (compiler-driver-emit-lowered-result
    (CompilerDriverOutputRoute.Pic)
    input-path
    lowered
    target
    has-target
    mode
    opt-level
    emit-entry
    crt-entry
    false)
    [(Emitted (Pic output) advisories) (Ok output advisories)]
    [(Emitted (Err diagnostic) advisories) (Err diagnostic advisories)]
    [_ (io.panic "compiler driver: unexpected emit result")]))

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
      (while true
        (match (sym_i64_env.sym-i64-view cursor)
          [(SymI64ViewNil) (return true)]
          [(SymI64ViewBind key value rest)
            (if (= key compiler_parse_core.compiler-parse-state-marker-id)
              (set! cursor rest)
              (if (and
                (sym_i64_env.sym-i64-contains-id right key)
                (= value (sym_i64_env.sym-i64-lookup-id-or right key -1)))
                (set! cursor rest)
                (return false)))]))
      false)))

(cfg
  embedded-stdlib-tlci
  (define (compiler-driver-cfgs-match-default?
    [actual : sym_i64_env.SymI64Env]
    [target : be_state.CompilerBackendTarget]) : bool
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
      [(compiler-driver-cfgs-match-default? cfgs (Linux)) "linux-default"]
      [(compiler-driver-cfgs-match-default? cfgs (Windows)) "windows-default"]
      [else ""])))

(cfg
  embedded-stdlib-tlci
  (define (compiler-driver-prelude-surface-key-valid?
    [key : (& key surface_identity.SurfaceIdentityKey)]
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
      (build_identity.compiler-build-producer-identity))
      [(ExactMatch)
        (match (tlci.tlci-aux-checked-directory (& rodata))
          [(or (Missing) (Err _)) Missing]
          [(Ok checked)
            (match (compiler_surface_hydrate.compiler-surface-key
              (& rodata)
              (& checked))
              [(or (Missing) (Err _)) Missing]
              [(Ok key)
                (if (not
                  (compiler-driver-prelude-surface-key-valid?
                    key
                    outer-build
                    expected-source-hash
                    configuration))
                  Missing
                  (match (compiler_surface_hydrate.compiler-surface-hydrate
                    (& rodata)
                    (& checked)
                    (& key)
                    (compiler_load.compiler-load-session-state-structural-session
                      (& load-state))
                    pools)
                    [(or (Missing) (KeyMismatch _) (Err _)) Missing]
                    [(Ok hydration)
                      (let
                        [ast : surface_ast.SurfaceAstHydration hydration.ast]
                        [facts : surface_facts.SurfaceTypecheckFacts
                          hydration.facts]
                        (if (surface_facts.surface-typecheck-facts-publish!
                          facts)
                          (Ok ast.decls ast.paths ast.modules ast.seen)
                          Missing))]))])])]
      [_ Missing])))

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
        (compiler_load.compiler-load-stdlib-root-configured? (& stdlib-roots))
        (= (string.string-length configuration) 0))
        Missing
        (in-arena
          (unsafe
            (arena.Arena surface-arena))
          (match (embedded_tlci.compiler-embedded-stdlib-tlci-surface
            surface-arena)
            [(Unavailable _) Missing]
            [(Ok outer-build source-hash rodata)
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
  (compiler-driver-profile-note-prelude-source-pipeline! profile-state)
  (match (compiler_load.compiler-load-stdlib-prelude-file-with-roots-cfg
    (& (compiler_load.compiler-load-runtime-prelude-path-shared-view))
    (sym_i64_env.sym-i64-empty)
    (& stdlib-roots)
    cfgs)
    [(Ok runtime-decls runtime-paths runtime-modules runtime-seen)
      (match (compiler_load.compiler-load-core-macro-prelude-with-roots-cfg
        runtime-seen
        (& stdlib-roots)
        cfgs)
        [(Ok macro-decls macro-paths macro-modules macro-seen)
          (Ok
            (compiler_load.compiler-load-decl-list-append
              (& runtime-decls)
              (& macro-decls))
            (compiler_load.compiler-load-decl-path-list-append
              (& runtime-paths)
              (& macro-paths))
            (compiler_load.compiler-load-decl-module-list-append
              (& runtime-modules)
              (& macro-modules))
            macro-seen)]
        [(Err diag) (Err diag)])]
    [(Err diag) (Err diag)]))

(define (compiler-driver-load-runtime-prelude-cache-miss-and-profile-state
  [key : compiler_load.CompilerLoadPreludeCacheKey]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (in-arena
    (unsafe
      (arena.Arena compiler_ast_types.node-pool-base-arena))
    (let
      [persistent-key : compiler_load.CompilerLoadPreludeCacheKey
        (compiler_load.compiler-load-prelude-cache-key-copy key)]
      [cold : compiler_load.ResultCompilerLoadWithPaths
        (compiler-driver-load-runtime-prelude-cold-and-profile-state
          stdlib-roots
          cfgs
          profile-state)]
      (match (owned_view.compiler-owned-shared-view cold)
        [(Ok decls paths modules seen)
          (compiler-driver-runtime-prelude-cache-store
            persistent-key
            decls
            paths
            modules
            seen)]
        [(Err _) unit])
      cold)))

(define (compiler-driver-load-runtime-prelude-and-profile-state
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (if (and
    (not (compiler_load.compiler-load-tli-active?))
    (compiler_load.compiler-load-session-cache-enabled?))
    (let
      [key : compiler_load.CompilerLoadPreludeCacheKey
        (compiler_load.compiler-load-runtime-prelude-cache-key
          (& stdlib-roots)
          cfgs)]
      (match (compiler-driver-runtime-prelude-cache-lookup key)
        [(CompilerLoadPreludeCacheHit decls paths modules seen)
          (Ok decls paths modules seen)]
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

(define (compiler-driver-load-file-with-runtime-and-profile-state
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  ;; Prepend the implicit prelude (runtime + core macros), then load the entry.
  (match (compiler-driver-load-runtime-prelude-and-profile-state
    (owned_view.compiler-owned-shared-view stdlib-roots)
    cfgs
    profile-state)
    [(Ok prelude-decls prelude-paths prelude-modules prelude-seen)
      (match (compiler_load.compiler-load-entry-file-with-paths-and-roots-cfg
        (& input-path)
        prelude-seen
        (& stdlib-roots)
        cfgs)
        [(Ok entry-decls entry-paths entry-modules seen)
          (Ok
            (compiler_load.compiler-load-decl-list-append
              (& prelude-decls)
              (& entry-decls))
            (compiler_load.compiler-load-decl-path-list-append
              (& prelude-paths)
              (& entry-paths))
            (compiler_load.compiler-load-decl-module-list-append
              (& prelude-modules)
              (& entry-modules))
            seen)]
        [(Err diag) (Err diag)])]
    [(Err diag) (Err diag)]))

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
    (& stdlib-roots)
    cfgs)
    [(Ok prelude-decls prelude-paths prelude-modules prelude-seen)
      (match (compiler_load.compiler-load-entry-file-with-paths-and-roots-cfg
        (& input-path)
        prelude-seen
        (& stdlib-roots)
        cfgs)
        [(Ok entry-decls entry-paths entry-modules seen)
          (Ok
            (compiler_load.compiler-load-decl-list-append
              (& prelude-decls)
              (& entry-decls))
            (compiler_load.compiler-load-decl-path-list-append
              (& prelude-paths)
              (& entry-paths))
            (compiler_load.compiler-load-decl-module-list-append
              (& prelude-modules)
              (& entry-modules))
            seen)]
        [(Err diag) (Err diag)])]
    [(Err diag) (Err diag)]))

(define (compiler-driver-load-runtime-prelude-cold-with-pools
  [load-state : compiler_load.CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler-driver-profile-note-prelude-source-pipeline! profile-state)
  (compiler_load.compiler-load-executable-prelude
    load-state
    stdlib-roots
    cfgs
    pools))

(define (compiler-driver-load-runtime-prelude-cache-miss-with-state-and-pools
  [load-state : compiler_load.CompilerLoadSessionState]
  [key : compiler_load.CompilerLoadPreludeCacheKey]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (in-arena
    (unsafe
      (arena.Arena (compiler_ast_types.ast-node-pool-context-base-arena pools)))
    (let
      [persistent-key : compiler_load.CompilerLoadPreludeCacheKey
        (compiler_load.compiler-load-prelude-cache-key-copy key)]
      [cold : compiler_load.ResultCompilerLoadWithPaths
        (compiler-driver-load-runtime-prelude-cold-with-pools
          (owned_view.compiler-owned-shared-view load-state)
          stdlib-roots
          cfgs
          pools
          profile-state)]
      (match (owned_view.compiler-owned-shared-view cold)
        [(Ok decls paths modules seen)
          (compiler-driver-runtime-prelude-cache-store-with-state-and-pools
            load-state
            persistent-key
            decls
            paths
            modules
            seen
            pools)]
        [(Err _) unit])
      cold)))

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
          (& stdlib-roots)
          cfgs)]
      (match (compiler-driver-runtime-prelude-cache-lookup-with-state
        (owned_view.compiler-owned-shared-view load-state)
        key)
        [(CompilerLoadPreludeCacheHit decls paths modules seen)
          (Ok decls paths modules seen)]
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
  (if (compiler_load.compiler-load-session-state-tli-active? (& load-state))
    (compiler-driver-load-runtime-prelude-cold-with-pools
      load-state
      stdlib-roots
      cfgs
      pools
      profile-state)
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
            cfgs
            pools
            surface-arena)]
        [_surface-end : unit
          (cfg
            compile-startup-profile
            (startup_profile.compiler-startup-profile-mark-surface-end!)
            unit)]
        (match surface
          [(Missing)
            (compiler-driver-load-runtime-prelude-ordinary-with-state-and-pools
              load-state
              stdlib-roots
              cfgs
              pools
              profile-state)]
          [(Ok decls paths modules seen)
            ;; Hydration bypasses the ordinary stdlib source loader, so record
            ;; the embedded provenance that loader would have attached. Macro
            ;; routing must not depend on an unrelated later import happening
            ;; to resolve core_macros.tl from the embedded payload.
            (compiler_load.compiler-load-session-state-note-embedded-module!
              load-state
              (&
                (compiler_load.compiler-load-core-macro-prelude-path-shared-view)))
            ;; core_macros imports stdlib.clone for the late typed helper
            ;; splice. Hydration bypasses that import's ordinary source
            ;; provenance hook too, and the late splice runs after the primary
            ;; macro walk, so name the transitive macro owner explicitly.
            (compiler_load.compiler-load-session-state-note-embedded-module!
              load-state
              (& (compiler_load.compiler-load-clone-prelude-path-shared-view)))
            (compiler_load.compiler-load-session-state-note-embedded-module!
              load-state
              (& (compiler_load.compiler-load-runtime-prelude-path-shared-view)))
            (compiler_load.compiler-load-session-state-note-embedded-stdlib-source!
              load-state)
            (compiler-driver-profile-note-prelude-hydration! profile-state)
            (compiler_load.ResultCompilerLoadWithPaths.Ok
              decls
              paths
              modules
              seen)]))
      (compiler-driver-load-runtime-prelude-ordinary-with-state-and-pools
        load-state
        stdlib-roots
        cfgs
        pools
        profile-state))))

(define (compiler-driver-load-runtime-prelude-with-state-and-pools
  [load-state : compiler_load.CompilerLoadSessionState]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]
  [profile-state : profile_state.CompilerProfileState]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler-driver-load-runtime-prelude-with-state-pools-and-surface
    load-state
    stdlib-roots
    cfgs
    pools
    0
    profile-state))

(define (compiler-driver-load-file-with-runtime-with-state-pools-and-surface
  [load-state : compiler_load.CompilerLoadSessionState]
  [input-path : (& input-path str)]
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
        cfgs
        pools
        surface-arena
        profile-state)]
    [_prelude-end : unit
      (cfg
        compile-startup-profile
        (startup_profile.compiler-startup-profile-mark-prelude-end!)
        unit)]
    (match prelude
      [(Ok prelude-decls prelude-paths prelude-modules prelude-seen)
        (begin
          (cfg
            compile-startup-profile
            (startup_profile.compiler-startup-profile-mark-user-entry-start!)
            unit)
          (match (compiler_load.compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
            load-state
            input-path
            prelude-seen
            (& stdlib-roots)
            cfgs
            pools)
            [(Ok entry-decls entry-paths entry-modules seen)
              (Ok
                (compiler_load.compiler-load-decl-list-append
                  (& prelude-decls)
                  (& entry-decls))
                (compiler_load.compiler-load-decl-path-list-append
                  (& prelude-paths)
                  (& entry-paths))
                (compiler_load.compiler-load-decl-module-list-append
                  (& prelude-modules)
                  (& entry-modules))
                seen)]
            [(Err diag) (Err diag)]))]
      [(Err diag) (Err diag)])))

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
    cfgs
    pools
    profile-state)
    [(Ok prelude-decls prelude-paths prelude-modules prelude-seen)
      (match (compiler_load.compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
        load-state
        (& input-path)
        (& source)
        prelude-seen
        (& stdlib-roots)
        No
        cfgs
        pools)
        [(Ok entry-decls entry-paths entry-modules seen)
          (Ok
            (compiler_load.compiler-load-decl-list-append
              (& prelude-decls)
              (& entry-decls))
            (compiler_load.compiler-load-decl-path-list-append
              (& prelude-paths)
              (& entry-paths))
            (compiler_load.compiler-load-decl-module-list-append
              (& prelude-modules)
              (& entry-modules))
            seen)]
        [(Err diag) (Err diag)])]
    [(Err diag) (Err diag)]))

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
  [input-path : (& input-path str)]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : compiler_ast_types.AstNodePoolContext]) : compiler_load.ResultCompilerLoadWithPaths
  (match (compiler_load.compiler-load-core-macro-prelude-with-roots-cfg-with-pools
    (owned_view.compiler-owned-shared-view load-state)
    (sym_i64_env.sym-i64-empty)
    (& stdlib-roots)
    cfgs
    pools)
    [(Ok prelude-decls prelude-paths prelude-modules prelude-seen)
      (match (compiler_load.compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
        load-state
        input-path
        prelude-seen
        (& stdlib-roots)
        cfgs
        pools)
        [(Ok entry-decls entry-paths entry-modules seen)
          (Ok
            (compiler_load.compiler-load-decl-list-append
              (& prelude-decls)
              (& entry-decls))
            (compiler_load.compiler-load-decl-path-list-append
              (& prelude-paths)
              (& entry-paths))
            (compiler_load.compiler-load-decl-module-list-append
              (& prelude-modules)
              (& entry-modules))
            seen)]
        [(Err diag) (Err diag)])]
    [(Err diag) (Err diag)]))

(define (compiler-driver-apply-tli-hydrated-lowered-result!
  [load-state : (& compiler_load.CompilerLoadSessionState)]
  [lowered : (& ResultCompilerDriverLowered)]) : unit
  (match lowered
    [(Ok _ _ _ _ backend-state _ _)
      (compiler-driver-apply-tli-hydrated-backend-state!
        load-state
        backend-state)]
    [_ unit]))

(define (compiler-driver-load-and-lower-escaping-with-opt-level-and-profile-state
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [opt-level : i64]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverLowered
  (match (compiler-driver-open-tli-catalog-for-session!
    (& (compiler_load.compiler-load-serial-test-session-state))
    (& input-path)
    (compiler-driver-target-cfg-from-backend target)
    (& stdlib-roots)
    cfgs
    opt-level
    true)
    [(Err tli-msg)
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start input-path tli-msg))
        (compiler-driver-serial-advisories))]
    [(Ok)
      (match (compiler-driver-load-file-with-runtime
        (owned_view.compiler-owned-shared-view input-path)
        (owned_view.compiler-owned-shared-view stdlib-roots)
        cfgs)
        [(Ok decls paths modules _)
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase profile-state "load"))
            (cfg
              compile-profile
              (compiler-driver-profile-start-phase profile-state))
            (match (compiler_lower.lower-compiler-program-with-decl-paths-mode-cache
              (owned_view.compiler-owned-shared-view input-path)
              (compiler_ast_types.ast-program decls)
              (compiler_ast_types.ast-decl-path-list-with-modules
                paths
                (& modules))
              (compiler-driver-lower-mode-for-target target mode)
              (owned_view.compiler-owned-shared-view stdlib-roots)
              cfgs
              (compiler_load.compiler-load-prelude-cache-key
                "typecheck-prefix-lower"
                (& stdlib-roots)
                cfgs))
              [(Ok program spans lower-state)
                (begin
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase profile-state "lower"))
                  (if (compiler_ast_types.ast-node-pool-reader-type-exhausted?)
                    (begin
                      (compiler_load.compiler-load-tli-release!)
                      (compiler-driver-release-lower-arenas-after-emit!
                        lower-state)
                      (Err
                        (box
                          (compiler-driver-ty-node-pool-exhausted-diagnostic
                            input-path))
                        (compiler-driver-serial-advisories)))
                    (let
                      [active-load : compiler_load.CompilerLoadSessionState
                        (compiler_load.compiler-load-serial-test-session-state)]
                      [hydrated-program : compiler_ir_types.CompilerIrProgram
                        (compiler-driver-hydrate-tli-compact-ir!
                          (& active-load)
                          (compiler_ast_types.ast-node-pool-reader-context-current)
                          program
                          opt-level)]
                      [lowered-res : ResultCompilerDriverLowered
                        (compiler-driver-lowered-from-active-pools-and-profile-state
                          hydrated-program
                          spans
                          profile-state
                          lower-state)]
                      (compiler-driver-apply-tli-hydrated-lowered-result!
                        (& active-load)
                        (& lowered-res))
                      (compiler_load.compiler-load-tli-release!)
                      lowered-res)))]
              [(Err diag)
                (begin
                  (compiler_load.compiler-load-tli-release!)
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase profile-state "lower"))
                  (Err diag (compiler-driver-serial-advisories)))]))]
        [(Err diag)
          (begin
            (compiler_load.compiler-load-tli-release!)
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase profile-state "load"))
            (Err diag (compiler-driver-serial-advisories)))])]))

(define (compiler-driver-load-and-lower-escaping-and-profile-state
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverLowered
  (compiler-driver-load-and-lower-escaping-with-opt-level-and-profile-state
    input-path
    target
    stdlib-roots
    mode
    cfgs
    2
    profile-state))

(define (compiler-driver-load-and-lower-escaping
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : be_state.CompilerBackendMode]
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
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [profile-state : profile_state.CompilerProfileState]) : ResultCompilerDriverLowered
  (match (compiler-driver-load-file-for-pic-image
    (owned_view.compiler-owned-shared-view input-path)
    (owned_view.compiler-owned-shared-view stdlib-roots)
    cfgs)
    [(Ok decls paths modules _)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase profile-state "load"))
        (cfg
          compile-profile
          (compiler-driver-profile-start-phase profile-state))
        (match (compiler_lower.lower-compiler-program-with-decl-paths-mode-cache
          (owned_view.compiler-owned-shared-view input-path)
          (compiler_ast_types.ast-program decls)
          (compiler_ast_types.ast-decl-path-list-with-modules paths (& modules))
          (compiler-driver-lower-mode-for-target target mode)
          (owned_view.compiler-owned-shared-view stdlib-roots)
          cfgs
          (compiler_load.compiler-load-prelude-cache-key
            "typecheck-prefix-lower"
            (& stdlib-roots)
            cfgs))
          [(Ok program spans lower-state)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase profile-state "lower"))
              (if (compiler_ast_types.ast-node-pool-reader-type-exhausted?)
                (begin
                  (compiler-driver-release-lower-arenas-after-emit! lower-state)
                  (Err
                    (box
                      (compiler-driver-ty-node-pool-exhausted-diagnostic
                        input-path))
                    (compiler-driver-serial-advisories)))
                (compiler-driver-lowered-from-active-pools-and-profile-state
                  program
                  spans
                  profile-state
                  lower-state)))]
          [(Err diag)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase profile-state "lower"))
              (Err diag (compiler-driver-serial-advisories)))]))]
    [(Err diag)
      (begin
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase profile-state "load"))
        (Err diag (compiler-driver-serial-advisories)))]))

(define (compiler-driver-load-and-lower-pic-image
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverLowered
  (compiler-driver-load-and-lower-pic-image-and-profile-state
    input-path
    target
    stdlib-roots
    mode
    cfgs
    (profile_state.compiler-profile-state-new)))

;; This bookkeeping lives in the retained state surface, never in a source
;; arena that checked generation or macro compaction may retire mid-call.
(defstruct CompilerDriverCheckedLowerHandoff
  (dest-pools compiler_ast_types.AstNodePoolContext)
  (entry-arena i64)
  (source-pools-arena i64))

(defstruct CompilerDriverCheckedLowerResult
  (lowered compiler_lower.ResultCompilerLower)
  (pools compiler_ast_types.AstNodePoolContext)
  (committed bool)
  (frontend-released bool))

(define (compiler-driver-state-begin-checked-lower!
  [state : CompilerDriverState]
  [pools : compiler_ast_types.AstNodePoolContext]
  [frontend-arena : i64]) : CompilerDriverCheckedLowerHandoff
  (let
    [release-source-pools? : bool
      (compiler-driver-state-can-release-checked-lower-source-pools? state)]
    [dest-pools : compiler_ast_types.AstNodePoolContext
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
          (compiler_lower.compiler-lower-profile-pools
            "checked_pool"
            dest-pools)
          unit))]
    [entry-arena : i64 (arena.tl_arena_current)]
    ;; Preserve the exact pool owner from its context. The active allocation
    ;; arena can instead be the distinct frontend owner; it is not a substitute
    ;; for the pool's stable root handle.
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
          (compiler-driver-state-owned-lower-state state)
          dest-pools
          source-pools-arena
          (compiler_ast_types.ast-node-pool-context-expr-storage-arena pools)
          (compiler_ast_types.ast-node-pool-context-type-storage-arena pools)
          frontend-arena)
        (compiler_lower.compiler-lower-checked-dest-pools-clear!
          (compiler-driver-state-owned-lower-state state)))]
    (in-arena
      (unsafe
        (arena.Arena (compiler-driver-state-surface-arena state)))
      (CompilerDriverCheckedLowerHandoff
        dest-pools
        entry-arena
        source-pools-arena))))

(define (compiler-driver-state-finish-checked-lower!
  [state : CompilerDriverState]
  [pools : compiler_ast_types.AstNodePoolContext]
  [handoff : CompilerDriverCheckedLowerHandoff]
  [lowered-raw : compiler_lower.ResultCompilerLower]) : CompilerDriverCheckedLowerResult
  (let
    [release-source-pools? : bool
      (compiler-driver-state-can-release-checked-lower-source-pools? state)]
    [dest-pools : compiler_ast_types.AstNodePoolContext handoff.dest-pools]
    [entry-arena : i64 handoff.entry-arena]
    [source-pools-arena : i64 handoff.source-pools-arena]
    [lowered : compiler_lower.ResultCompilerLower
      (match lowered-raw
        [(Ok program spans lower-state) (Ok program spans lower-state)]
        [(Err diag)
          (Err
            (compiler-driver-diagnostic-copy-to-state-surface
              (owned_view.compiler-owned-shared-view state)
              diag))])]
    [dest-committed? : bool
      (compiler_lower.compiler-lower-checked-dest-pools-committed?
        (compiler-driver-state-owned-lower-state state))]
    [frontend-released? : bool
      (compiler_lower.compiler-lower-checked-frontend-released?
        (compiler-driver-state-owned-lower-state state))]
    [result-pools : compiler_ast_types.AstNodePoolContext
      (if dest-committed?
        (compiler_lower.compiler-lower-checked-dest-pools-current
          (compiler-driver-state-owned-lower-state state))
        pools)]
    [_adopt-dest : unit
      (if dest-committed?
        (compiler-driver-state-adopt-pools! state result-pools)
        unit)]
    [_destroy-unused-dest : unit
      (when
        (and release-source-pools? (not dest-committed?))
        (compiler_lower.compiler-lower-checked-dest-pools-abort-uncommitted!
          (compiler-driver-state-owned-lower-state state))
        (compiler-driver-state-destroy-uncommitted-pools! dest-pools))]
    [_restore-entry-arena : unit
      (if release-source-pools?
        (unsafe
          (arena.tl_arena_set
            (if frontend-released?
              compiler-driver-pending-frontend-return-arena
              (if (and dest-committed? (= entry-arena source-pools-arena))
                (compiler_ast_types.ast-node-pool-context-base-arena
                  result-pools)
                entry-arena))))
        unit)]
    [_clear-release : unit
      (compiler_lower.compiler-lower-checked-dest-pools-clear!
        (compiler-driver-state-owned-lower-state state))]
    ;; A failed lower may already have retired source or checked storage.
    ;; Re-own a live empty context before outer batch/file cleanup can inspect
    ;; or release the state again. Refs #5448.
    [_own-error-pools : unit
      (match (& lowered)
        [(Err _)
          (when
            release-source-pools?
            ;; Before first commit the original source is live; after final
            ;; commit the adopted checked pool is live. Reuse the canonical
            ;; replacement owner to release that storage, including when its
            ;; arena is current. Rollover abort has already destroyed both
            ;; generations, so that path must not inspect the stale context.
            (if (or dest-committed? (not frontend-released?))
              (compiler-driver-state-release-owned-pool-arena-if-uncached!
                (owned_view.compiler-owned-shared-view state))
              (compiler-driver-state-adopt-pools!
                state
                (compiler-driver-state-new-checked-lower-pools)))
            (set! result-pools (compiler-driver-state-pool-context state)))]
        [(Ok _ _ _) unit])]
    (in-arena
      (unsafe
        (arena.Arena (compiler-driver-state-surface-arena state)))
      (CompilerDriverCheckedLowerResult
        lowered
        result-pools
        dest-committed?
        frontend-released?))))

(define (compiler-driver-load-and-lower-escaping-with-state-and-retirement
  [state : CompilerDriverState]
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [retire-after-lower? : bool]
  [opt-level : i64]) : ResultCompilerDriverLowered
  (let
    [_configure-input : unit
      (compiler-driver-lower-state-configure-input!
        (compiler-driver-state-owned-lower-state state)
        opt-level)]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler-driver-state-pool-context state)]
    [release-source-pools? : bool
      (compiler-driver-state-can-release-checked-lower-source-pools? state)]
    [route-source-allocations? : bool
      (and release-source-pools? retire-after-lower?)]
    [frontend-arena : i64
      (if route-source-allocations?
        (arena.tl_arena_make)
        0)]
    [_use-frontend-arena : unit
      (when
        route-source-allocations?
        (set!
          compiler-driver-pending-frontend-return-arena
          (arena.tl_arena_current))
        (unsafe
          (arena.tl_arena_set frontend-arena)))]
    [_install-interns : unit (compiler-driver-state-install-interns! state)]
    [_profile-load-lifetime-start : unit
      (cfg
        compile-profile
        (compiler-driver-profile-start-load-lifetime!
          (compiler-driver-state-profile state)
          pools
          (compiler-driver-state-surface-arena state)
          (compiler_parse_core.compiler-parse-state-control-addr
            (& state.parser-state)))
        unit)]
    [parser-state : compiler_parse_core.CompilerParseState
      (owned_view.compiler-owned-shared-view state.parser-state)]
    [parse-cfgs : sym_i64_env.SymI64Env
      (compiler_parse_core.compiler-parse-state-cfgs (& parser-state) cfgs)]
    ;; The sysroot archive is compiled for the executable code model (non-PIC),
    ;; so shared-object compiles stay on source stdlib.
    (match (if (be_state.compiler-backend-state-shared-object-code-model?
      (compiler-driver-state-backend (& state)))
      (begin
        (compiler-driver-clear-last-hydrated-archive-path!)
        (compiler_load.compiler-load-session-state-tli-release!
          (& state.load-session))
        tli_cli.ResultTliCatalogOpen.Ok)
      (compiler-driver-open-tli-catalog-for-session!
        (& state.load-session)
        (& input-path)
        (compiler-driver-target-cfg-from-backend target)
        (& stdlib-roots)
        cfgs
        opt-level
        true))
      [(Err tli-msg)
        (let
          [return-arena : i64 compiler-driver-pending-frontend-return-arena]
          (when
            route-source-allocations?
            (set! compiler-driver-pending-frontend-return-arena 0)
            (unsafe
              (arena.tl_arena_set return-arena)))
          ;; The message was built in the frontend arena: copy it into the
          ;; caller's arena before that arena is destroyed.
          (let
            [failed : ResultCompilerDriverLowered
              (Err
                (box
                  (compiler_diagnostic.compiler-diagnostic-at-start
                    input-path
                    (string.copy (& tli-msg))))
                (compiler-driver-state-advisories state))]
            (when
              route-source-allocations?
              (unsafe
                (arena.tl_arena_destroy frontend-arena)))
            failed))]
      [(Ok)
        (match (compiler-driver-load-file-with-runtime-with-state-pools-and-surface
          (owned_view.compiler-owned-shared-view state.load-session)
          input-path
          (owned_view.compiler-owned-shared-view stdlib-roots)
          parse-cfgs
          pools
          (compiler-driver-state-surface-arena state)
          (compiler-driver-state-profile state))
          [(Ok decls paths modules _)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-emit-load-lifetime!
                  (compiler-driver-state-profile state)
                  pools
                  (compiler-driver-state-surface-arena state)
                  (compiler_load.compiler-load-session-state-tli-arenas
                    (& state.load-session))
                  "load.complete"
                  (compiler_parse_core.compiler-parse-state-control-addr
                    (& state.parser-state))))
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase
                  (compiler-driver-state-profile state)
                  "load"))
              (cfg
                compile-profile
                (compiler-driver-profile-prelude-counters
                  (compiler-driver-state-profile state)))
              (compiler-driver-allocation-profile-snapshot-for-job!
                (compiler-driver-state-typecheck state)
                "load"
                (compiler-driver-state-owned-lower-state state))
              (compiler-driver-allocation-profile-pool-storage-snapshot!
                "source-load"
                pools)
              (cfg
                compile-profile
                (compiler_lower.compiler-lower-profile-pools
                  "source_load"
                  pools)
                unit)
              ;; Load has returned its declaration list, so the lexer token buffer
              ;; and the reader node pool's spare capacity are dead scan scratch
              ;; that would otherwise sit on the retain.program/retain.release
              ;; peak for the rest of the process. Retire them here, on the same
              ;; uncached single-entry gate the source-arena retirement uses, so a
              ;; session that reuses loader state across jobs keeps its warm
              ;; capacity.
              (if route-source-allocations?
                (compiler_load.compiler-load-transfer-frontend-handoff!)
                unit)
              (cfg
                compile-profile
                (compiler-driver-profile-emit-load-lifetime!
                  (compiler-driver-state-profile state)
                  pools
                  (compiler-driver-state-surface-arena state)
                  (compiler_load.compiler-load-session-state-tli-arenas
                    (& state.load-session))
                  "load.handoff"
                  (compiler_parse_core.compiler-parse-state-control-addr
                    (& state.parser-state))))
              (cfg
                compile-profile
                (compiler-driver-profile-start-phase
                  (compiler-driver-state-profile state)))
              ;; Parsing initialized builtin IDs for this state's active intern
              ;; table. Preserve that snapshot instead of reinstalling the stale
              ;; pre-parse builtin state.
              (compiler-driver-state-capture-active-builtins! (&mut state))
              (compiler-driver-state-install-pools! state)
              (let
                [_capture-source-names : unit
                  (compiler-driver-state-capture-active-interns! (&mut state))]
                [source-names : ci.InternSourceNameSessionHandle
                  (compiler-driver-state-entry-source-name-session
                    (owned_view.compiler-owned-shared-view state))]
                [checked-handoff : CompilerDriverCheckedLowerHandoff
                  (compiler-driver-state-begin-checked-lower!
                    (owned_view.compiler-owned-shared-view state)
                    pools
                    (if route-source-allocations?
                      frontend-arena
                      0))]
                [lowered-raw : compiler_lower.ResultCompilerLower
                  (compiler_lower.lower-compiler-program-with-decl-paths-mode-cache-and-pools-and-source-names-and-load-state-and-intern-state
                    (compiler-driver-state-owned-lower-state state)
                    (owned_view.compiler-owned-shared-view state.load-session)
                    (owned_view.compiler-owned-shared-view
                      state.typecheck-prefix-cache)
                    state.typecheck-state
                    (owned_view.compiler-owned-shared-view input-path)
                    (compiler_ast_types.ast-program decls)
                    (compiler_ast_types.ast-decl-path-list-with-modules
                      paths
                      (& modules))
                    (compiler-driver-lower-mode-for-target target mode)
                    (owned_view.compiler-owned-shared-view stdlib-roots)
                    cfgs
                    (compiler_load.compiler-load-prelude-cache-key
                      "typecheck-prefix-lower"
                      (& stdlib-roots)
                      cfgs)
                    pools
                    source-names
                    (compiler-driver-state-owned-interns state)
                    (compiler-driver-state-owned-builtins
                      (owned_view.compiler-owned-shared-view state)))]
                [checked : CompilerDriverCheckedLowerResult
                  (compiler-driver-state-finish-checked-lower!
                    (owned_view.compiler-owned-shared-view state)
                    pools
                    checked-handoff
                    lowered-raw)]
                [lowered : compiler_lower.ResultCompilerLower checked.lowered]
                [dest-committed? : bool checked.committed]
                [frontend-released? : bool checked.frontend-released]
                [result-pools : compiler_ast_types.AstNodePoolContext
                  checked.pools]
                (match lowered
                  [(Ok program spans lower-state)
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
                        (compiler_lower.compiler-lower-profile-pools
                          "macro_detach"
                          result-pools)
                        unit)
                      ;; Typecheck re-enters the loader for macro-materialized
                      ;; imports and surface-summary refreshes, so both scan owners
                      ;; can have regrown a fresh arena since the load boundary.
                      ;; Retire them again now that no frontend work remains: the
                      ;; optimizer, backend, and writer never lex or read.
                      (if route-source-allocations?
                        (compiler_load.compiler-load-transfer-frontend-handoff!)
                        unit)
                      (compiler-driver-state-prefix-cache-allocation-profile-snapshot!
                        state
                        "lower")
                      (compiler-driver-allocation-profile-snapshot-for-job!
                        (compiler-driver-state-typecheck state)
                        "lower"
                        (compiler-driver-state-owned-lower-state state))
                      (if (compiler_ast_types.ast-node-pool-context-type-exhausted?
                        pools)
                        (begin
                          (compiler_load.compiler-load-session-state-tli-release!
                            (& state.load-session))
                          (Err
                            (box
                              (compiler-driver-ty-node-pool-exhausted-diagnostic
                                input-path))
                            (compiler-driver-state-advisories state)))
                        (if (and dest-committed? retire-after-lower?)
                          (let
                            [hydrated-program : compiler_ir_types.CompilerIrProgram
                              (begin
                                (when
                                  (and
                                    route-source-allocations?
                                    (not frontend-released?))
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
                                (compiler-driver-hydrate-tli-compact-ir!
                                  (& state.load-session)
                                  result-pools
                                  program
                                  opt-level))]
                            (compiler-driver-state-capture-active-interns!
                              (&mut state))
                            (compiler-driver-finish-tli-hydrated-session! state)
                            (compiler-driver-state-retain-lowered-types!
                              state
                              hydrated-program
                              spans
                              result-pools))
                          (let
                            [hydrated-program : compiler_ir_types.CompilerIrProgram
                              (compiler-driver-hydrate-tli-compact-ir!
                                (& state.load-session)
                                result-pools
                                program
                                opt-level)]
                            (compiler-driver-state-capture-active-interns!
                              (&mut state))
                            (compiler-driver-finish-tli-hydrated-session! state)
                            (compiler-driver-lowered-from-pools-and-profile-state-and-backend-state
                              hydrated-program
                              spans
                              result-pools
                              (compiler-driver-state-profile state)
                              (compiler-driver-state-backend state)
                              (compiler-driver-state-typecheck state)
                              (compiler-driver-state-owned-lower-state state))))))]
                  [(Err diag)
                    (begin
                      (compiler_load.compiler-load-session-state-tli-release!
                        (& state.load-session))
                      (cfg
                        compile-profile
                        (compiler-driver-profile-finish-phase
                          (compiler-driver-state-profile state)
                          "lower"))
                      (compiler-driver-state-prefix-cache-allocation-profile-snapshot!
                        state
                        "lower")
                      (compiler-driver-allocation-profile-snapshot-for-job!
                        (compiler-driver-state-typecheck state)
                        "lower"
                        (compiler-driver-state-owned-lower-state state))
                      (Err diag (compiler-driver-state-advisories state)))])))]
          [(Err diag)
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-emit-load-lifetime!
                  (compiler-driver-state-profile state)
                  pools
                  (compiler-driver-state-surface-arena state)
                  (compiler_load.compiler-load-session-state-tli-arenas
                    (& state.load-session))
                  "load.complete"
                  (compiler_parse_core.compiler-parse-state-control-addr
                    (& state.parser-state))))
              (compiler_load.compiler-load-session-state-tli-release!
                (& state.load-session))
              (cfg
                compile-profile
                (compiler-driver-profile-finish-phase
                  (compiler-driver-state-profile state)
                  "load"))
              (compiler-driver-allocation-profile-snapshot-for-job!
                (compiler-driver-state-typecheck state)
                "load"
                (compiler-driver-state-owned-lower-state state))
              (Err diag (compiler-driver-state-advisories state)))])])))

(define (compiler-driver-load-and-lower-pic-image-with-state-and-retirement
  [state : CompilerDriverState]
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [retire-after-lower? : bool]
  [opt-level : i64]) : ResultCompilerDriverLowered
  (let
    [_configure-input : unit
      (compiler-driver-lower-state-configure-input!
        (compiler-driver-state-owned-lower-state state)
        opt-level)]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler-driver-state-pool-context state)]
    [_install-interns : unit (compiler-driver-state-install-interns! state)]
    [_profile-load-lifetime-start : unit
      (cfg
        compile-profile
        (compiler-driver-profile-start-load-lifetime!
          (compiler-driver-state-profile state)
          pools
          (compiler-driver-state-surface-arena state)
          (compiler_parse_core.compiler-parse-state-control-addr
            (& state.parser-state)))
        unit)]
    [parser-state : compiler_parse_core.CompilerParseState
      (owned_view.compiler-owned-shared-view state.parser-state)]
    [parse-cfgs : sym_i64_env.SymI64Env
      (compiler_parse_core.compiler-parse-state-cfgs (& parser-state) cfgs)]
    (match (compiler-driver-load-file-for-pic-image-with-pools
      (owned_view.compiler-owned-shared-view state.load-session)
      input-path
      (owned_view.compiler-owned-shared-view stdlib-roots)
      parse-cfgs
      pools)
      [(Ok decls paths modules _)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-emit-load-lifetime!
              (compiler-driver-state-profile state)
              pools
              (compiler-driver-state-surface-arena state)
              (__tl_make-array i64 0)
              "load.complete"
              (compiler_parse_core.compiler-parse-state-control-addr
                (& state.parser-state))))
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
            (compiler_lower.compiler-lower-profile-pools "source_load" pools)
            unit)
          ;; Same frontend scan-scratch retirement as the escaping path above,
          ;; on the same uncached single-entry gate.
          (if (and
            retire-after-lower?
            (compiler-driver-state-can-release-checked-lower-source-pools?
              state))
            (compiler_load.compiler-load-transfer-frontend-handoff!)
            unit)
          (cfg
            compile-profile
            (compiler-driver-profile-emit-load-lifetime!
              (compiler-driver-state-profile state)
              pools
              (compiler-driver-state-surface-arena state)
              (__tl_make-array i64 0)
              "load.handoff"
              (compiler_parse_core.compiler-parse-state-control-addr
                (& state.parser-state))))
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase
              (compiler-driver-state-profile state)))
          (compiler-driver-state-capture-active-builtins! (&mut state))
          (compiler-driver-state-install-pools! state)
          (let
            [_capture-source-names : unit
              (compiler-driver-state-capture-active-interns! (&mut state))]
            [intern-state : ci.InternCompatState
              (compiler-driver-state-owned-interns state)]
            [source-names : ci.InternSourceNameSessionHandle
              (ci.intern-source-name-session-handle
                (ci.intern-source-name-session-from-state intern-state))]
            [release-source-pools? : bool
              (compiler-driver-state-can-release-checked-lower-source-pools?
                state)]
            [checked-handoff : CompilerDriverCheckedLowerHandoff
              (compiler-driver-state-begin-checked-lower!
                (owned_view.compiler-owned-shared-view state)
                pools
                0)]
            [lowered-raw : compiler_lower.ResultCompilerLower
              (compiler_lower.lower-compiler-program-with-decl-paths-mode-cache-and-pools-and-source-names-and-load-state-and-intern-state
                (compiler-driver-state-owned-lower-state state)
                (owned_view.compiler-owned-shared-view state.load-session)
                (owned_view.compiler-owned-shared-view
                  state.typecheck-prefix-cache)
                state.typecheck-state
                (owned_view.compiler-owned-shared-view input-path)
                (compiler_ast_types.ast-program decls)
                (compiler_ast_types.ast-decl-path-list-with-modules
                  paths
                  (& modules))
                (compiler-driver-lower-mode-for-target target mode)
                (owned_view.compiler-owned-shared-view stdlib-roots)
                cfgs
                (compiler_load.compiler-load-prelude-cache-key
                  "typecheck-prefix-lower"
                  (& stdlib-roots)
                  cfgs)
                pools
                source-names
                (compiler-driver-state-owned-interns state)
                (compiler-driver-state-owned-builtins
                  (owned_view.compiler-owned-shared-view state)))]
            [checked : CompilerDriverCheckedLowerResult
              (compiler-driver-state-finish-checked-lower!
                (owned_view.compiler-owned-shared-view state)
                pools
                checked-handoff
                lowered-raw)]
            [lowered : compiler_lower.ResultCompilerLower checked.lowered]
            [dest-committed? : bool checked.committed]
            [result-pools : compiler_ast_types.AstNodePoolContext checked.pools]
            (match lowered
              [(Ok program spans lower-state)
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
                    (compiler_lower.compiler-lower-profile-pools
                      "macro_detach"
                      result-pools)
                    unit)
                  ;; Same post-lower retirement as the escaping path above.
                  (if (and retire-after-lower? release-source-pools?)
                    (compiler_load.compiler-load-transfer-frontend-handoff!)
                    unit)
                  (if (compiler_ast_types.ast-node-pool-context-type-exhausted?
                    pools)
                    (Err
                      (box
                        (compiler-driver-ty-node-pool-exhausted-diagnostic
                          input-path))
                      (compiler-driver-state-advisories state))
                    (if (and dest-committed? retire-after-lower?)
                      (compiler-driver-state-retain-lowered-types!
                        state
                        program
                        spans
                        result-pools)
                      (compiler-driver-lowered-from-pools-and-profile-state-and-backend-state
                        program
                        spans
                        result-pools
                        (compiler-driver-state-profile state)
                        (compiler-driver-state-backend state)
                        (compiler-driver-state-typecheck state)
                        (compiler-driver-state-owned-lower-state state)))))]
              [(Err diag)
                (begin
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase
                      (compiler-driver-state-profile state)
                      "lower"))
                  (Err diag (compiler-driver-state-advisories state)))])))]
      [(Err diag)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-emit-load-lifetime!
              (compiler-driver-state-profile state)
              pools
              (compiler-driver-state-surface-arena state)
              (__tl_make-array i64 0)
              "load.complete"
              (compiler_parse_core.compiler-parse-state-control-addr
                (& state.parser-state))))
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase
              (compiler-driver-state-profile state)
              "load"))
          (Err diag (compiler-driver-state-advisories state)))])))

(define (compiler-driver-load-and-lower-pic-image-with-state
  [state : CompilerDriverState]
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [opt-level : i64]) : ResultCompilerDriverLowered
  (compiler-driver-load-and-lower-pic-image-with-state-and-retirement
    state
    input-path
    target
    stdlib-roots
    mode
    cfgs
    false
    opt-level))

(define (compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [crt-entry : bool]
  [closed-executable : bool]) : ResultCompilerDriver
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (cfg compile-profile (compiler-driver-profile-start-total profile-state))
      ;; The lowering provenance side table is remapped after
      ;; optimization so backend diagnostics report surviving instruction
      ;; locations when a rewrite can preserve them.
      (compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt
        (owned_view.compiler-owned-shared-view input-path)
        (compiler-driver-load-and-lower-escaping-with-opt-level-and-profile-state
          input-path
          target
          stdlib-roots
          mode
          (compiler-driver-target-cfgs target cfgs)
          opt-level
          profile-state)
        target
        has-target
        mode
        opt-level
        true
        crt-entry
        closed-executable))))

(define (compiler-driver-emit-file-object-image-with-target-roots-level-mode-cfg-and-crt
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [crt-entry : bool]
  [closed-executable : bool]) : ResultCompilerDriverObject
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (cfg compile-profile (compiler-driver-profile-start-total profile-state))
      (compiler-driver-emit-lowered-result-object-image-with-level-mode-entry-and-crt
        (owned_view.compiler-owned-shared-view input-path)
        (compiler-driver-load-and-lower-escaping-with-opt-level-and-profile-state
          input-path
          target
          stdlib-roots
          mode
          (compiler-driver-target-cfgs target cfgs)
          opt-level
          profile-state)
        target
        has-target
        mode
        opt-level
        true
        crt-entry
        closed-executable))))

(define (compiler-driver-state-emit-file-buffer-with-target-roots-level-mode-and-cfg
  [state : CompilerDriverState]
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [emit-entry : bool]) : ResultCompilerDriverBuffer
  (begin
    (cfg
      compile-profile
      (compiler-driver-profile-start-total
        (compiler-driver-state-profile state)))
    (let
      [lowered : ResultCompilerDriverLowered
        (compiler-driver-load-and-lower-escaping-with-state-and-retirement
          (owned_view.compiler-owned-shared-view state)
          (owned_view.compiler-owned-shared-view input-path)
          target
          stdlib-roots
          mode
          (compiler-driver-state-target-cfgs state target cfgs)
          (>= opt-level 1)
          opt-level)]
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
        emit-entry
        (and
          emit-entry
          (be_state.compiler-backend-target-elf? target)
          (cfg_core.compiler-cfg-enabled?
            cfgs
            (ci.intern "closed-executable-image")))))))

(define (compiler-driver-state-emit-file-pic-with-target-roots-level-mode-and-cfg
  [state : CompilerDriverState]
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriverPic
  (begin
    (cfg
      compile-profile
      (compiler-driver-profile-start-total
        (compiler-driver-state-profile state)))
    (let
      [lowered : ResultCompilerDriverLowered
        (compiler-driver-load-and-lower-pic-image-with-state-and-retirement
          (owned_view.compiler-owned-shared-view state)
          (owned_view.compiler-owned-shared-view input-path)
          target
          stdlib-roots
          mode
          (compiler-driver-state-target-cfgs state target cfgs)
          (>= opt-level 1)
          opt-level)]
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

;; Compatibility selector assignments can allocate aggregate descriptors.
;; Publish every restored carrier in the enclosing owner's arena, never in the
;; frontend/job arena that the caller is about to retire.
(define (compiler-driver-restore-parent-session!
  [home : arena.Arena]
  [parent : compiler_load.CompilerLoadSessionState]
  [pools : compiler_ast_types.AstNodePoolContext]
  [interns : ci.InternCompatState]
  [builtins : cbi.CompilerBuiltinIdsState]) : unit
  (in-arena
    home
    (unsafe
      ;; unsafe: installs global intern state; replaced before this arena ends
      (ci.intern-compat-state-install! interns))
    (unsafe
      ;; unsafe: installs global AST pool state; replaced before this arena ends
      (compiler_ast_types.ast-node-pool-context-install! pools))
    (if (array-ref parent.intern-state-ready 0)
      (unsafe
        ;; unsafe: installs the global load session; replaced before this arena ends
        (compiler_load.compiler-load-session-state-use-with-intern-state!
          parent
          (compiler_load.compiler-load-session-state-interns parent)))
      (unsafe
        ;; unsafe: installs the global load session; replaced before this arena ends
        (compiler_load.compiler-load-session-state-use! parent)))
    (compiler_typecheck_core.compiler-typecheck-reset-intern-owned-state!)
    (unsafe
      ;; unsafe: resets global analysis state; it holds no allocation of this arena
      (compiler-driver-reset-analysis-state!))
    (cbi.state-install! (& builtins))))

;; This scope's carrier belongs to the outer package-job scratch arena. Its
;; frontend and pool arenas can be retired while that carrier remains live.
(defstruct CompilerDriverPackageRuntimeScope
  (state CompilerDriverState)
  (frontend-arena (__tl_dyn-array i64))
  (home arena.Arena)
  (home-pools compiler_ast_types.AstNodePoolContext)
  (home-interns ci.InternCompatState)
  (home-builtins cbi.CompilerBuiltinIdsState)
  (parent compiler_load.CompilerLoadSessionState)
  (home-profile-pool i64)
  (home-profile-surface i64)
  (job arena.Arena)
  (released (__tl_dyn-array bool)))

(define (compiler-driver-package-runtime-scope-new [home : arena.Arena]) : CompilerDriverPackageRuntimeScope
  (let
    [home-pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [home-interns : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [home-builtins : cbi.CompilerBuiltinIdsState (cbi.state-capture)]
    [parent : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-active-session-state-shared-view)]
    [home-profile-pool : i64
      (array-ref compiler-driver-active-state-pool-arena 0)]
    [home-profile-surface : i64
      (array-ref compiler-driver-active-state-surface-arena 0)]
    [_reset-analysis : unit (compiler-driver-reset-analysis-state!)]
    [state : CompilerDriverState
      (compiler-driver-state-new-for-compile-with-load-session
        (compiler_load.compiler-load-session-state-new-for-package-child
          (& parent)))]
    [frontend : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (set! (array-ref frontend 0) (arena.tl_arena_make))
    (compiler-driver-state-install-pools! state)
    (compiler-driver-state-install-interns! state)
    (compiler_load.compiler-load-session-state-use! state.load-session)
    (compiler_typecheck_core.compiler-typecheck-reset-intern-owned-state!)
    (CompilerDriverPackageRuntimeScope
      state
      frontend
      home
      home-pools
      home-interns
      home-builtins
      parent
      home-profile-pool
      home-profile-surface
      (arena.current)
      (__tl_make-array bool 1))))

;; Call while the package-job carrier arena is current, after every escaped
;; output has been copied to home and before native export compilation begins.
(define (compiler-driver-package-runtime-scope-release!
  [scope : CompilerDriverPackageRuntimeScope]) : unit
  (if (array-ref scope.released 0)
    unit
    (in-arena
      scope.job
      (set! (array-ref scope.released 0) true)
      (let
        [state : CompilerDriverState scope.state]
        (compiler-driver-retire-lowered-source-arena!)
        (compiler-driver-retire-frontend-arena!)
        (compiler-driver-state-release-file-state!
          (owned_view.compiler-owned-shared-view state))
        (compiler-driver-state-prefix-cache-clear! state)
        (compiler_backend.compiler-backend-state-release-final-arenas!
          (compiler-driver-state-backend state))
        (compiler_load.compiler-load-transfer-frontend-handoff!)
        (let
          [retired : compiler_ast_types.AstNodePoolContext
            (compiler-driver-state-pool-context state)]
          [intern-arena : i64
            (ci.intern-compat-state-persistent-arena
              (& (array-ref state.intern-state 0)))]
          (compiler-driver-restore-parent-session!
            scope.home
            scope.parent
            scope.home-pools
            scope.home-interns
            scope.home-builtins)
          (set!
            (array-ref compiler-driver-active-state-pool-arena 0)
            scope.home-profile-pool)
          (set!
            (array-ref compiler-driver-active-state-surface-arena 0)
            scope.home-profile-surface)
          (compiler_ast_types.ast-node-pool-context-destroy-storage! retired)
          (ci.intern-compat-state-release-structural-generations!
            (&mut (array-ref state.intern-state 0)))
          (unsafe
            (begin
              (arena.tl_arena_destroy
                (compiler_ast_types.ast-node-pool-context-base-arena retired))
              (arena.tl_arena_destroy intern-arena)
              (cfg
                embedded-stdlib-tlci
                (embedded_tlci.compiler-embedded-stdlib-tlci-forget-decoded!
                  state.surface-arena))
              (arena.tl_arena_destroy state.surface-arena)
              (unless
                (= (array-ref scope.frontend-arena 0) 0)
                (arena.tl_arena_destroy (array-ref scope.frontend-arena 0)))))
          (set! (array-ref scope.frontend-arena 0) 0))))))

;; Serial loading can update the live pool/interner carriers even when a
;; later import fails. Capture immediately after load, before matching its
;; result; cleanup must own the last live generation on both exits.
(define (compiler-driver-package-runtime-capture-frontend!
  [scope : CompilerDriverPackageRuntimeScope]) : unit
  (let
    [state : CompilerDriverState scope.state]
    (compiler-driver-state-adopt-pools!
      state
      (compiler_ast_types.ast-node-pool-context-capture-active))
    (compiler-driver-state-capture-active-interns! (&mut state))
    (compiler-driver-state-capture-active-builtins! (&mut state))))

(define (compiler-driver-package-runtime-open-tli!
  [scope : CompilerDriverPackageRuntimeScope]
  [entry-path : (& str)]
  [manifest-dir : (& str)]
  [deps : (& compiler_load.CompilerPkgDeps)]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : (& svec.Vec)]
  [cfgs : sym_i64_env.SymI64Env]
  [opt-level : i64]
  [require-archive : bool]) : tli_cli.ResultTliCatalogOpen
  (compiler-driver-open-package-tli-catalogs-for-session!
    (& scope.state.load-session)
    entry-path
    manifest-dir
    deps
    (compiler-driver-target-cfg-from-backend target)
    stdlib-roots
    cfgs
    opt-level
    require-archive))

(define (compiler-driver-package-runtime-load
  [scope : CompilerDriverPackageRuntimeScope]
  [path : String]
  [roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]) : compiler_load.ResultCompilerLoadWithPaths
  (let
    [loaded : compiler_load.ResultCompilerLoadWithPaths
      (in-arena
        (unsafe
          (arena.Arena (array-ref scope.frontend-arena 0)))
        (compiler-driver-load-package-file-with-runtime-cfg
          path
          roots
          manifest-dir
          deps
          emit-entry
          cfgs))]
    (compiler-driver-package-runtime-capture-frontend! scope)
    loaded))

(define (compiler-driver-package-runtime-lower
  [scope : CompilerDriverPackageRuntimeScope]
  [package-name : String]
  [target : be_state.CompilerBackendTarget]
  [mode : be_state.CompilerBackendMode]
  [decls : compiler_ast_types.AstDeclList]
  [paths : compiler_ast_types.AstDeclPathList]
  [cfgs : sym_i64_env.SymI64Env]
  [opt-level : i64]) : ResultCompilerDriverLowered
  (let
    [state : CompilerDriverState
      (owned_view.compiler-owned-shared-view scope.state)]
    [_configure-input : unit
      (compiler-driver-lower-state-configure-input!
        (compiler-driver-state-owned-lower-state state)
        opt-level)]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [_capture : unit
      (begin
        ;; Package-owned paths and export preparation can intern additional
        ;; identities after loading. Publish that final frontend cursor before
        ;; generation installs the explicit job interner.
        (compiler-driver-package-runtime-capture-frontend!
          (owned_view.compiler-owned-shared-view scope))
        ;; Hydrated dependency facts include frontend-owned observation arrays.
        ;; Keep their complete publication live through generation/macro source
        ;; retirement; file-state reset clears it before this arena is destroyed.
        (in-arena
          (unsafe
            (arena.Arena (compiler-driver-state-surface-arena state)))
          (surface_facts.surface-typecheck-facts-retain-current!))
        (compiler_lower.compiler-lower-state-set-spmd-package!
          (compiler-driver-state-owned-lower-state state)
          package-name)
        (compiler_load.compiler-load-transfer-frontend-handoff!))]
    [source-names : ci.InternSourceNameSessionHandle
      (compiler-driver-state-entry-source-name-session
        (owned_view.compiler-owned-shared-view state))]
    [_route : unit
      (begin
        (set!
          compiler-driver-pending-frontend-return-arena
          (__tl-project-field scope.home handle))
        (unsafe
          (arena.tl_arena_set (array-ref scope.frontend-arena 0))))]
    [handoff : CompilerDriverCheckedLowerHandoff
      (compiler-driver-state-begin-checked-lower!
        (owned_view.compiler-owned-shared-view state)
        pools
        (array-ref scope.frontend-arena 0))]
    [raw : compiler_lower.ResultCompilerLower
      (compiler_lower.lower-compiler-program-with-decl-paths-mode-cache-and-pools-and-source-names-and-load-state-and-intern-state
        (compiler-driver-state-owned-lower-state state)
        (owned_view.compiler-owned-shared-view state.load-session)
        (owned_view.compiler-owned-shared-view state.typecheck-prefix-cache)
        state.typecheck-state
        ""
        (compiler_ast_types.ast-program decls)
        paths
        (compiler-driver-lower-mode-for-target target mode)
        (svec.new)
        cfgs
        (compiler_typecheck_core.tc-prefix-default-cache-scope)
        pools
        source-names
        (compiler-driver-state-owned-interns state)
        (compiler-driver-state-owned-builtins
          (owned_view.compiler-owned-shared-view state)))]
    [checked : CompilerDriverCheckedLowerResult
      (compiler-driver-state-finish-checked-lower!
        (owned_view.compiler-owned-shared-view state)
        pools
        handoff
        raw)]
    [_finish-tli : unit
      (compiler-driver-finish-tli-hydrated-session! (& state))]
    [_frontend : unit
      (begin
        (unless
          checked.frontend-released
          (set!
            compiler-driver-pending-retired-frontend-arena
            (array-ref scope.frontend-arena 0)))
        (set! (array-ref scope.frontend-arena 0) 0)
        (unsafe
          (arena.tl_arena_set compiler-driver-pending-frontend-return-arena)))]
    (match checked.lowered
      [(Ok program spans lower-state)
        (compiler-driver-state-retain-lowered-types!
          state
          program
          spans
          checked.pools)]
      [(Err diag) (Err diag (compiler-driver-state-advisories state))])))

(define (compiler-driver-load-package-file-with-runtime-cfg
  [input-path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler_load.compiler-load-package-file-with-runtime-cfg
    (& input-path)
    (& stdlib-roots)
    (& manifest-dir)
    (& deps)
    emit-entry
    cfgs))

(define (compiler-driver-load-package-file-with-runtime
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]) : compiler_load.ResultCompilerLoadWithPaths
  (compiler-driver-load-package-file-with-runtime-cfg
    input-path
    stdlib-roots
    manifest-dir
    deps
    emit-entry
    (compiler-driver-target-cfgs
      target
      (compiler_parse_core.compiler-cfg-empty))))

(defenum ResultCompilerDriverPackagePaths
  (Ok compiler_ast_types.AstDeclPathList)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(define (clone-result-compiler-driver-package-paths
  [value : (& value ResultCompilerDriverPackagePaths)]) : ResultCompilerDriverPackagePaths
  (match value
    [(Ok paths) (Ok (compiler_ast_types.clone-ast-decl-path-list paths))]
    [(Err diag)
      (Err
        (box (compiler_diagnostic.clone-compiler-diagnostic (& (deref diag)))))]))

;; Only copied strings cross the discovery boundary. Interned ownership and
;; provenance ids belong to the retiring session, and are deliberately absent.
(define (compiler-driver-copy-package-discovery-paths
  [paths : compiler_ast_types.AstDeclPathList]) : compiler_ast_types.AstDeclPathList
  (match (compiler_ast_types.ast-decl-path-list-step paths)
    [(Nil) (compiler_ast_types.ast-decl-path-list-new)]
    [(Cons path rest)
      (compiler_ast_types.ast-decl-path-list-prepend-builder-with-owner-and-provenance-id
        (string.copy path)
        -1
        -1
        (compiler-driver-copy-package-discovery-paths rest))]))

;; Serial preflight boundary: callers retain manifest/root/dependency strings,
;; while discovery owns every parsed node, interned name and derived surface.
;; Restore the enclosing session before freeing the temporary owners so the
;; following doctest (including inline worker fallback) starts with live state.
(define (compiler-driver-load-package-discovery-paths
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [cfg-names : (& cfg-names svec.Vec)]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]
  [include-module-holders : bool]) : ResultCompilerDriverPackagePaths
  (let
    [home : arena.Arena (arena.current)]
    [parent : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-active-session-state-shared-view)]
    [home-pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [home-interns : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [home-builtins : cbi.CompilerBuiltinIdsState (cbi.state-capture)]
    (with-scratch
      (let
        [pools : compiler_ast_types.AstNodePoolContext
          (compiler_ast_types.ast-node-pool-context-new-with-capacities-in-arena
            1
            1
            (arena.tl_arena_current))]
        [interns : ci.InternCompatState (ci.intern-compat-state-new)]
        [state : compiler_load.CompilerLoadSessionState
          (compiler_load.compiler-load-session-state-new-for-package-child
            (& parent))]
        [_install-pools : unit
          (unsafe
            ;; unsafe: installs global AST pool state; replaced before this arena ends
            (compiler_ast_types.ast-node-pool-context-install! pools))]
        [_install-interns : unit
          (unsafe
            ;; unsafe: installs global intern state; replaced before this arena ends
            (ci.intern-compat-state-install! interns))]
        [_install-session
          : unit
          ;; This boundary uses the serial loader, whose parser advances the
          ;; active interner cursor. Capture that live owner through the serial
          ;; session adapter instead of retaining a pre-parse scalar snapshot.
          (unsafe
            ;; unsafe: installs the global load session; replaced before this arena ends
            (compiler_load.compiler-load-session-state-use! state))]
        [_reset-intern-caches : unit
          (compiler_typecheck_core.compiler-typecheck-reset-intern-owned-state!)]
        [_reset-analysis : unit
          (unsafe
            ;; unsafe: resets global analysis state; it holds no allocation of this arena
            (compiler-driver-reset-analysis-state!))]
        [discovery-cfgs : sym_i64_env.SymI64Env
          (unsafe
            ;; unsafe: interned cfg names live in the persistent intern arena
            (compiler-driver-target-cfgs
              target
              (target_cfg.compiler-target-user-cfgs cfg-names)))]
        [_open-tli : unit
          (unsafe
            ;; unsafe: TLI bundles own their own arenas and are released below
            (match (tli_cli.tli-open-transitive-package-deps-for-session!
              (& state)
              (& manifest-dir)
              (& deps)
              (compiler-driver-target-cfg-from-backend target)
              discovery-cfgs
              false)
              [(Ok) unit]
              [(Err _)
                (compiler_load.compiler-load-session-state-tli-release!
                  (& state))
                (compiler_load.compiler-load-session-state-set-dependency-tlci-force-source!
                  (owned_view.compiler-owned-shared-view state)
                  true)]))]
        [result : ResultCompilerDriverPackagePaths
          (match (unsafe
            ;; unsafe: publishes global surface facts; cleared before this arena ends
            ;; unsafe: interned names live in the persistent intern arena, not this one
            (compiler-driver-load-package-file-with-runtime-cfg
              (string.copy (& input-path))
              stdlib-roots
              manifest-dir
              deps
              emit-entry
              discovery-cfgs))
            [(Ok _ paths _ seen)
              (in-arena
                home
                (Ok
                  (if include-module-holders
                    (compiler_load.compiler-load-package-reachable-paths
                      (& input-path)
                      (& paths)
                      seen)
                    (compiler-driver-copy-package-discovery-paths paths))))]
            [(Err diag)
              (in-arena
                home
                (Err
                  (box
                    (compiler_diagnostic.compiler-diagnostic-copy (deref diag)))))])]
        [_release-tli : unit
          (compiler_load.compiler-load-session-state-tli-release! (& state))]
        [retired-pools : compiler_ast_types.AstNodePoolContext
          (compiler_ast_types.ast-node-pool-context-capture-active)]
        [intern-arena : i64 (ci.intern-persistent-arena-handle)]
        (unsafe
          ;; unsafe: resets a global cache; it keeps no allocation of this arena
          (compiler_load.compiler-load-session-reset-pools!))
        ;; No declarations escape, so the reader's origin prefix is empty.
        ;; The normal handoff now releases all scan capacity as well.
        (unsafe
          ;; unsafe: releases the global token buffers; they keep no allocation of this arena
          (compiler_load.compiler-load-transfer-frontend-handoff!))
        (unsafe
          ;; unsafe: installs the global load session; replaced before this arena ends
          ;; unsafe: installs global intern state; replaced before this arena ends
          (compiler-driver-restore-parent-session!
            home
            parent
            home-pools
            home-interns
            home-builtins))
        (compiler_ast_types.ast-node-pool-context-destroy-storage!
          retired-pools)
        (ci.intern-compat-state-release-structural-generations! (&mut interns))
        (unsafe
          (arena.tl_arena_destroy intern-arena))
        result))))

(define (compiler-driver-load-package-paths-with-runtime
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [cfg-names : (& cfg-names svec.Vec)]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]) : ResultCompilerDriverPackagePaths
  (compiler-driver-load-package-discovery-paths
    input-path
    target
    cfg-names
    stdlib-roots
    manifest-dir
    deps
    emit-entry
    false))

(define (compiler-driver-load-package-preflight-paths
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [cfg-names : (& cfg-names svec.Vec)]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]) : ResultCompilerDriverPackagePaths
  (compiler-driver-load-package-discovery-paths
    input-path
    target
    cfg-names
    stdlib-roots
    manifest-dir
    deps
    emit-entry
    true))

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
    [(Ok decls paths modules seen)
      (Ok
        (owned_view.compiler-owned-shared-view decls)
        (compiler_load.compiler-load-package-owned-paths-for-decls
          (& package-owner)
          (& manifest-dir)
          (& stdlib-roots)
          (& input-path)
          (& decls)
          (& paths))
        modules
        seen)]
    [(Err diag) (Err diag)]))

(define (compiler-driver-ir-summary-line [name : String] [value : i64]) : String
  (str_cat.str-cat name " " (string.int->string value) "\n"))

(define (compiler-driver-ir-summary-render
  [summary : compiler_ir_types.CompilerIrSummary]) : String
  (let
    [out : String "typelisp-ir-summary v1\n"]
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
          (compiler_ir_types.compiler-ir-summary-max-instructions-block summary))
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
      "")))

(define (compiler-driver-emit-ir-summary-lowered-with-level
  [pools : compiler_ast_types.AstNodePoolContext]
  [backend-state : be_state.CompilerBackendState]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [opt-level : i64]
  [profile-state : profile_state.CompilerProfileState]
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [lower-state : compiler_lower.CompilerLowerState]) : ResultCompilerDriver
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic ""))
      (compiler-driver-advisories-for-job typecheck-state))
    (match (compiler-driver-optimize-lowered
      pools
      backend-state
      program
      spans
      opt-level
      profile-state
      typecheck-state
      lower-state
      (compiler_ir_types.compiler-ir-representation-index-empty)
      (CompilerDriverOutputRoute.Ir))
      [(Program optimized _)
        (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
          (Err
            (box (compiler-driver-ty-node-pool-exhausted-diagnostic ""))
            (compiler-driver-advisories-for-job typecheck-state))
          (Ok
            (compiler-driver-ir-summary-render
              (compiler_ir_types.compiler-ir-program-summary (& optimized)))
            (compiler-driver-advisories-for-job typecheck-state)))])))

(define (compiler-driver-emit-ir-summary-lowered-result-with-level
  [lowered : ResultCompilerDriverLowered]
  [opt-level : i64]) : ResultCompilerDriver
  (match lowered
    [(Ok
        program
        spans
        pools
        profile-state
        _backend-state
        typecheck-state
        lower-state)
      (let
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              pools
              (& program))
            program)]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone-compiler-source-spans (& spans))
            spans)]
        [out : ResultCompilerDriver
          (begin
            (compiler_ast_types.ast-node-pool-reader-use! pools)
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-driver-emit-ir-summary-lowered-with-level
              pools
              _backend-state
              emit-program
              emit-spans
              opt-level
              profile-state
              typecheck-state
              lower-state))]
        (if (= opt-level 0)
          (compiler-driver-retire-lowered-source-arena!)
          unit)
        (compiler-driver-release-lower-arenas-after-emit! lower-state)
        (compiler_ast_types.ast-node-pool-reader-clear!)
        (compiler-driver-restore-frontend-return-arena!)
        out)]
    [(Err diag advisories)
      (compiler-driver-restore-frontend-return-arena!)
      (Err diag advisories)]))

(define (compiler-driver-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : be_state.CompilerBackendMode]
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
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerDriver
  (compiler-driver-emit-ir-summary-lowered-result-with-level
    (compiler-driver-load-and-lower-pic-image-with-state
      (owned_view.compiler-owned-shared-view state)
      input-path
      target
      stdlib-roots
      mode
      (compiler-driver-state-target-cfgs state target cfgs)
      opt-level)
    opt-level))

(define (compiler-driver-ir-text-result
  [structural-session : cis.InternStructuralSessionHandle]
  [type-segment-bases : i64]
  [optimized : compiler_ir_types.CompilerIrProgram]
  [dump-pass : String]
  [advisories : compiler_diagnostic.CompilerAdvisoryList]) : ResultCompilerDriver
  (let
    [verify-error : String
      (compiler_optimize.compiler-opt-debug-verification-error)]
    (if (> (string.string-length verify-error) 0)
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            (str_cat.str-cat "IR verification failed: " verify-error)))
        advisories)
      (let
        [text : String
          (if (> (string.string-length dump-pass) 0)
            (compiler_optimize.compiler-opt-debug-dump-result)
            (compiler_ir_types.compiler-ir-program-render
              structural-session
              type-segment-bases
              (& optimized)))]
        (if (and
          (> (string.string-length dump-pass) 0)
          (= (string.string-length text) 0))
          (Err
            (box
              (compiler_diagnostic.compiler-diagnostic-at-start
                ""
                (str_cat.str-cat "optimizer pass '" dump-pass "' did not run")))
            advisories)
          (Ok text advisories))))))

(define (compiler-driver-emit-ir-text-lowered-with-level
  [pools : compiler_ast_types.AstNodePoolContext]
  [backend-state : be_state.CompilerBackendState]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [opt-level : i64]
  [dump-pass : String]
  [profile-state : profile_state.CompilerProfileState]
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [lower-state : compiler_lower.CompilerLowerState]) : ResultCompilerDriver
  (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
    (Err
      (box (compiler-driver-ty-node-pool-exhausted-diagnostic ""))
      (compiler-driver-advisories-for-job typecheck-state))
    (match (compiler-driver-optimize-lowered
      pools
      backend-state
      program
      spans
      opt-level
      profile-state
      typecheck-state
      lower-state
      (compiler_ir_types.compiler-ir-representation-index-empty)
      (CompilerDriverOutputRoute.Ir))
      [(Program optimized _)
        (if (compiler_ast_types.ast-node-pool-context-type-exhausted? pools)
          (Err
            (box (compiler-driver-ty-node-pool-exhausted-diagnostic ""))
            (compiler-driver-advisories-for-job typecheck-state))
          (compiler-driver-ir-text-result
            (cis.intern-structural-session-handle-from-source-names
              (compiler_typecheck_core.tc-macro-state-source-names
                (compiler_typecheck_core.tc-job-state-macro-state
                  typecheck-state)))
            (compiler_ast_types.ast-node-pool-context-type-segment-bases pools)
            optimized
            dump-pass
            (compiler-driver-advisories-for-job typecheck-state)))])))

(define (compiler-driver-emit-ir-text-lowered-result-with-level
  [lowered : ResultCompilerDriverLowered]
  [opt-level : i64]
  [dump-pass : String]) : ResultCompilerDriver
  (match lowered
    [(Ok
        program
        spans
        pools
        profile-state
        _backend-state
        typecheck-state
        lower-state)
      (let
        [emit-program : compiler_ir_types.CompilerIrProgram
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (compiler_ir_types.compiler-ir-clone-program-shell
              pools
              (& program))
            program)]
        [emit-spans : compiler_ir_types.CompilerSourceSpans
          (if (compiler-driver-retirement-clone-shells? opt-level)
            (clone-compiler-source-spans (& spans))
            spans)]
        [out : ResultCompilerDriver
          (begin
            (compiler_ast_types.ast-node-pool-reader-use! pools)
            (if (>= opt-level 1)
              (compiler-driver-retire-lowered-source-arena!)
              unit)
            (compiler-driver-emit-ir-text-lowered-with-level
              pools
              _backend-state
              emit-program
              emit-spans
              opt-level
              dump-pass
              profile-state
              typecheck-state
              lower-state))]
        (if (= opt-level 0)
          (compiler-driver-retire-lowered-source-arena!)
          unit)
        (compiler-driver-release-lower-arenas-after-emit! lower-state)
        (compiler_ast_types.ast-node-pool-reader-clear!)
        (compiler-driver-restore-frontend-return-arena!)
        out)]
    [(Err diag advisories)
      (compiler-driver-restore-frontend-return-arena!)
      (Err diag advisories)]))

(define (compiler-driver-state-emit-ir-text-file-with-target-roots-level-mode-and-cfg
  [state : CompilerDriverState]
  [input-path : String]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : be_state.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [dump-pass : String]) : ResultCompilerDriver
  (compiler-driver-emit-ir-text-lowered-result-with-level
    (compiler-driver-load-and-lower-pic-image-with-state
      (owned_view.compiler-owned-shared-view state)
      input-path
      target
      stdlib-roots
      mode
      (compiler-driver-state-target-cfgs state target cfgs)
      opt-level)
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
    [sources : CompilerDriverDiagnosticSources
      (compiler-driver-diagnostic-sources-new)]
    (compiler-driver-render-source-diagnostic-from (&mut sources) diag)))

;; The source texts a batch of diagnostics renders against. Each path is read
;; and line-indexed once, the first time a diagnostic names it, however many
;; diagnostics follow and in whatever order their files interleave (#7895). A
;; path that cannot be read is kept as the empty text, as a one-shot render
;; treats it.
(defstruct CompilerDriverDiagnosticSources
  (paths (__tl_dyn-array String))
  (sources (__tl_dyn-array compiler_diagnostic.CompilerDiagnosticSource))
  (count i64))

(define (compiler-driver-diagnostic-sources-new) : CompilerDriverDiagnosticSources
  (CompilerDriverDiagnosticSources
    (__tl_make-array String 4)
    (__tl_make-array compiler_diagnostic.CompilerDiagnosticSource 4)
    0))

(define (compiler-driver-diagnostic-source-read [path : (& path str)]) : compiler_diagnostic.CompilerDiagnosticSource
  (compiler_diagnostic.compiler-diagnostic-source-index
    (if (string.eq path "")
      ""
      (match (io.try-read-file path)
        [(OkIoBytes source) (byte_buf.to-string source)]
        [(ErrIoBytes _) ""]))))

;; The slot holding `path`'s indexed text, reading and indexing it first when
;; no earlier diagnostic named it.
(define (compiler-driver-diagnostic-sources-slot
  [sources : (&mut sources CompilerDriverDiagnosticSources)]
  [path : String]) : i64
  (let
    [slot : i64 0]
    [found : i64 (- 0 1)]
    (while (< slot sources.count)
      (if (string.eq (array-ref sources.paths slot) path)
        (begin
          (set! found slot)
          (set! slot sources.count))
        (+= slot 1)))
    (if (>= found 0)
      found
      (begin
        (if (= sources.count (array-length sources.paths))
          (let
            [capacity : i64 (* 2 (array-length sources.paths))]
            [paths : (__tl_dyn-array String) (__tl_make-array String capacity)]
            [texts : (__tl_dyn-array
              compiler_diagnostic.CompilerDiagnosticSource)
              (__tl_make-array
                compiler_diagnostic.CompilerDiagnosticSource
                capacity)]
            (for [index (iterator.range 0 sources.count)]
              (set!
                (array-ref paths index)
                (owned_view.compiler-owned-array-element-shared-view
                  sources.paths
                  index))
              (set!
                (array-ref texts index)
                (owned_view.compiler-owned-array-element-shared-view
                  sources.sources
                  index)))
            (set! sources.paths paths)
            (set! sources.sources texts))
          unit)
        (set!
          (array-ref sources.sources sources.count)
          (compiler-driver-diagnostic-source-read (& path)))
        (set! (array-ref sources.paths sources.count) path)
        (+= sources.count 1)
        (- sources.count 1)))))

;; `compiler-driver-render-source-diagnostic` for one diagnostic of a batch,
;; reusing the batch's already read and indexed texts.
(define (compiler-driver-render-source-diagnostic-from
  [sources : (&mut sources CompilerDriverDiagnosticSources)]
  [diag : compiler_diagnostic.CompilerDiagnostic]) : String
  (let
    [slot : i64
      (compiler-driver-diagnostic-sources-slot
        sources
        (compiler_load.compiler-load-prelude-source-path
          (& (compiler_diagnostic.compiler-diagnostic-path diag))
          (compiler_diagnostic.compiler-diagnostic-load-failure? (& diag))))]
    (compiler_diagnostic.compiler-diagnostic-render-indexed-source
      (& diag)
      (& (array-ref sources.sources slot)))))

(define (compiler-driver-append-advisories
  [advisories : (& advisories compiler_diagnostic.CompilerAdvisoryList)]
  [out : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [count : i64 (compiler_diagnostic.compiler-advisory-list-count advisories)]
    (if (= count 0)
      out
      (let
        [sources : CompilerDriverDiagnosticSources
          (compiler-driver-diagnostic-sources-new)]
        [buf : text_buf.TextBuf out]
        (for [index (iterator.range 0 count)]
          (let
            [advisory : compiler_diagnostic.CompilerAdvisory
              (compiler_diagnostic.compiler-advisory-list-get advisories index)]
            [diagnostic : compiler_diagnostic.CompilerDiagnostic
              (compiler_diagnostic.compiler-advisory-diagnostic (& advisory))]
            (text_buf.append!
              buf
              (compiler-driver-render-source-diagnostic-from
                (&mut sources)
                diagnostic))))
        buf))))

(define (compiler-driver-render-advisories
  [advisories : (& advisories compiler_diagnostic.CompilerAdvisoryList)]) : String
  (if (= (compiler_diagnostic.compiler-advisory-list-count advisories) 0)
    ""
    (text_buf.render
      (compiler-driver-append-advisories advisories (text_buf.empty)))))

(define (compiler-driver-print-advisories
  [advisories : (& advisories compiler_diagnostic.CompilerAdvisoryList)]) : unit
  (let
    [rendered : String (compiler-driver-render-advisories advisories)]
    (when (> (string.string-length (& rendered)) 0) (io.print-error rendered))))

(define (compiler-driver-write-result
  [_profile-state : profile_state.CompilerProfileState]
  [result : ResultCompilerDriver]
  [output-path : String]) : i64
  (match result
    [(Ok asm advisories)
      (begin
        (compiler-driver-print-advisories (& advisories))
        (cfg
          compile-profile
          (compiler-driver-profile-start-phase _profile-state))
        (io.write-file output-path (byte_buf.str-as-bytes (& asm)))
        (cfg
          compile-profile
          (compiler-driver-profile-finish-phase _profile-state "write"))
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total _profile-state))
        (io.print-format "{}" (str_cat.str-cat "Wrote " output-path "\n"))
        0)]
    [(Err diag advisories)
      (begin
        (compiler-driver-print-advisories (& advisories))
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total _profile-state))
        (io.print-error (compiler-driver-render-source-diagnostic (deref diag)))
        1)]))

(define (compiler-driver-write-buffer-result
  [_profile-state : profile_state.CompilerProfileState]
  [typecheck-state : compiler_typecheck_core.TcJobState]
  [result : ResultCompilerDriverBuffer]
  [output-path : String]
  [lower-state : compiler_lower.CompilerLowerState]) : i64
  (match result
    [(Ok buf advisories)
      (let
        [status : i64
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-start-phase _profile-state))
            (compiler-driver-write-text-buf
              (owned_view.compiler-owned-shared-view output-path)
              buf))]
        (begin
          (compiler-driver-print-advisories (& advisories))
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase _profile-state "write"))
          (compiler-driver-allocation-profile-snapshot-for-job!
            typecheck-state
            "write"
            lower-state)
          (compiler-driver-release-lower-arenas-after-emit! lower-state)
          (cfg
            compile-profile
            (compiler-driver-profile-finish-total _profile-state))
          (if (= status 0)
            (begin
              (io.print-format "{}" (str_cat.str-cat "Wrote " output-path "\n"))
              0)
            status)))]
    [(Err diag advisories)
      (begin
        (compiler-driver-print-advisories (& advisories))
        (compiler-driver-allocation-profile-snapshot-for-job!
          typecheck-state
          "write-error"
          lower-state)
        (compiler-driver-release-lower-arenas-after-emit! lower-state)
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total _profile-state))
        (io.print-error (compiler-driver-render-source-diagnostic (deref diag)))
        1)]))

(define (compiler-driver-pic-fixups-path [output-path : String]) : String
  (str_cat.str-cat output-path ".fixups"))

(define (compiler-driver-write-pic-result
  [_profile-state : profile_state.CompilerProfileState]
  [result : ResultCompilerDriverPic]
  [output-path : String]) : i64
  (match result
    [(Ok output advisories)
      (let
        [fixups-path : String
          (compiler-driver-pic-fixups-path
            (owned_view.compiler-owned-shared-view output-path))]
        (begin
          (compiler-driver-print-advisories (& advisories))
          (cfg
            compile-profile
            (compiler-driver-profile-start-phase _profile-state))
          (let
            [asm : String output.asm]
            [fixups : String output.fixups]
            (io.write-file output-path (byte_buf.str-as-bytes (& asm)))
            (io.write-file fixups-path (byte_buf.str-as-bytes (& fixups))))
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase _profile-state "write"))
          (cfg
            compile-profile
            (compiler-driver-profile-finish-total _profile-state))
          (io.print-format "{}" (str_cat.str-cat "Wrote " output-path "\n"))
          (io.print-format "{}" (str_cat.str-cat "Wrote " fixups-path "\n"))
          0))]
    [(Err diag advisories)
      (begin
        (compiler-driver-print-advisories (& advisories))
        (cfg
          compile-profile
          (compiler-driver-profile-finish-total _profile-state))
        (io.print-error (compiler-driver-render-source-diagnostic (deref diag)))
        1)]))