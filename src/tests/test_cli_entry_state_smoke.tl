;; Refs #7817. Entry retirement preserves borrowed serial selectors, and
;; loader cache payloads survive caller scratch but not their own reset.
(import test_cli_core as tltest)
(import compiler_load as load)
(import compiler_intern as ci)
(import compiler_owned_view as owned_view)
(import compiler_typecheck_core as tc)
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)
(import stdlib.runtime)
(import stdlib.profile)

(define (entry-selectors-restored? [result : i64]) : bool
  (let
    [parent : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    [parent-default : load.CompilerLoadSessionState
      (load.compiler-load-global-array-element-shared-view
        load.compiler-load-default-session-state
        0)]
    [parent-job : tc.TcJobState (tc.tc-serial-job-state)]
    [entry : tltest.TlTestEntry (tltest.tltest-entry-new)]
    [actual : i64 (tltest.tltest-entry-finish entry result)]
    [restored : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    [restored-default : load.CompilerLoadSessionState
      (load.compiler-load-global-array-element-shared-view
        load.compiler-load-default-session-state
        0)]
    [restored-job : tc.TcJobState (tc.tc-serial-job-state)]
    (and
      (= actual result)
      (= parent.shared-address restored.shared-address)
      (= parent-default.shared-address restored-default.shared-address)
      (= parent-job.address restored-job.address))))

(define (entry-bound-load-restored?) : bool
  (let
    [home : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    [parent : load.CompilerLoadSessionState
      (load.compiler-load-standalone-session-state-new)]
    [interns : ci.InternCompatState (ci.intern-compat-state-new)]
    [table-id : i64 (ci.intern-compat-state-table-id (& interns))]
    [_bind : unit
      (load.compiler-load-session-state-use-with-intern-state!
        (owned_view.compiler-owned-shared-view parent)
        interns)]
    [selectors-ok : bool (entry-selectors-restored? -7)]
    [restored : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    [restored-interns : ci.InternCompatState
      (load.compiler-load-session-state-interns
        (owned_view.compiler-owned-shared-view restored))]
    [ok : bool
      (and
        selectors-ok
        (array-ref restored.intern-state-ready 0)
        (= table-id (ci.intern-compat-state-table-id (& restored-interns))))]
    (begin
      (load.compiler-load-session-state-use! home)
      ok)))

(define (loader-cache-lifetime-ok?) : bool
  (let
    [state : load.CompilerLoadSessionState
      (load.compiler-load-standalone-session-state-new)]
    [scratch : arena.Arena (arena.make)]
    [_fill : unit
      (in-arena
        scratch
        (unless
          (string.eq
            (load.compiler-load-session-state-dotted-module-path-id
              (owned_view.compiler-owned-shared-view state)
              17
              "cache.scratch.owner")
            "cache/scratch/owner.tl")
          (io.panic "loader cache: miss path differs")))]
    [_retire-scratch : unit (arena.destroy-safe! scratch)]
    [hit : String
      (load.compiler-load-session-state-dotted-module-path-id
        (owned_view.compiler-owned-shared-view state)
        17
        "cache.scratch.owner")]
    [miss : String
      (load.compiler-load-session-state-dotted-module-path-id
        (owned_view.compiler-owned-shared-view state)
        18
        "cache.caller.copy")]
    [_reset : unit
      (load.compiler-load-session-state-dotted-path-cache-reset!
        (owned_view.compiler-owned-shared-view state))]
    (and
      (string.eq hit "cache/scratch/owner.tl")
      (string.eq miss "cache/caller/copy.tl")
      (= (array-ref state.dotted-path-cache-owner-arena 0) 0))))

(define (entry-preserves-view [result : i64]) : bool
  (let
    [text : String "parent-view-survives"]
    [view : (& text str) (string.slice-view (& text) 7 4)]
    [parent-owner : i64 (runtime.str-view-arena-current)]
    [parent : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    [entry : tltest.TlTestEntry (tltest.tltest-entry-new)]
    [entry-owner : i64 (runtime.str-view-arena-current)]
    [inside : bool
      (let
        [child : String "child-view"]
        [child-view : (& child str) (string.slice-view (& child) 6 4)]
        (and (string.eq child-view "view") (string.eq view "view")))]
    [actual : i64 (tltest.tltest-entry-finish entry result)]
    [restored : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    (and
      (> parent-owner 0)
      (> entry-owner 0)
      (not (= entry-owner parent-owner))
      inside
      (= actual result)
      (= parent-owner (runtime.str-view-arena-current))
      (= parent.shared-address restored.shared-address)
      (string.eq view "view"))))

;; A quiescent caller may not have initialized borrowed-view storage yet.
(define (entry-restores-uninitialized-view-owner?) : bool
  (let
    [home : i64 (runtime.str-view-arena-current)]
    [_clear : unit
      (unsafe
        (runtime.str-view-arena-use! 0))]
    [entry : tltest.TlTestEntry (tltest.tltest-entry-new)]
    [actual : i64 (tltest.tltest-entry-finish entry 0)]
    [restored : i64 (runtime.str-view-arena-current)]
    [_restore : unit
      (unsafe
        (runtime.str-view-arena-use! home))]
    (and (= actual 0) (= restored 0))))

(define (session-selection-does-not-retain?) : bool
  (let
    [home : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    [next : load.CompilerLoadSessionState
      (load.compiler-load-standalone-session-state-new)]
    [before : i64 (profile.alloc-live)]
    [index : i64 0]
    (begin
      (while (< index 128)
        (begin
          (load.compiler-load-session-state-use!
            (owned_view.compiler-owned-shared-view next))
          (load.compiler-load-session-state-use!
            (owned_view.compiler-owned-shared-view home))
          (set! index (+ index 1))))
      (and (> before 0) (= before (profile.alloc-live))))))

(define (main) : i64
  (begin
    (unless
      (and
        (entry-selectors-restored? 42)
        (entry-preserves-view 0)
        (entry-preserves-view 7)
        (entry-preserves-view -9)
        (entry-restores-uninitialized-view-owner?)
        (session-selection-does-not-retain?)
        (entry-bound-load-restored?)
        (loader-cache-lifetime-ok?))
      (io.panic "test CLI entry state: lifetime boundary failed"))
    42))