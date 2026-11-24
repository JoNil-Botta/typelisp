;; Refs #7817. Entry retirement preserves borrowed serial selectors, and
;; loader cache payloads survive caller scratch but not their own reset.
(import test_cli_core as tltest)
(import check_cli_core as check_cli)
(import compiler_check_core as check_core)
(import compiler_diagnostic as cdiag)
(import doc_test)
(import source_text_core as source_text)
(import compiler_load as load)
(import compiler_intern as ci)
(import compiler_owned_view as owned_view)
(import compiler_typecheck_core as tc)
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector String) as svec)

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
      (= tc.tc-entry-hidden-arena 0)
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
      (load.compiler-load-session-state-use-with-intern-state! parent interns)]
    [selectors-ok : bool (entry-selectors-restored? -7)]
    [restored : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    [restored-interns : ci.InternCompatState
      (load.compiler-load-session-state-interns restored)]
    [ok : bool
      (and
        selectors-ok
        (array-ref restored.intern-state-ready 0)
        (= table-id (ci.intern-compat-state-table-id (& restored-interns))))]
    (load.compiler-load-session-state-use! home)
    ok))

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

(define (check-batch-doctest-advisory-framing-ok?) : bool
  (let
    [warning : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-level
        (&
          (cdiag.compiler-diagnostic-simple
            "docs/advisory.tl.doctest.0"
            1
            22
            "unnecessary unsafe block"))
        CompilerDiagnosticWarning)]
    [advisories : cdiag.CompilerAdvisoryList
      (let
        [list : cdiag.CompilerAdvisoryList
          (cdiag.compiler-advisory-list-with-capacity 1)]
        (set!
          (array-ref list.slots 0)
          (cdiag.CompilerAdvisory
            (cdiag.CompilerAdvisoryPhase.Semantic)
            warning))
        (cdiag.CompilerAdvisoryList list.slots 1))]
    [advisories-out : svec.Vec (svec.new)]
    [check-res : doc_test.DocTestMaybeFailure
      (doc_test.doc-test-handle-check-result!
        "docs/advisory.tl"
        2
        0
        false
        (check_core.ResultCompilerCheck.Ok
          (CompilerTypecheckSummary 1 0 0)
          advisories)
        (&mut advisories-out))]
    [report : doc_test.DocTestRunReport
      (doc_test.DocTestRunReport.Report
        1
        (doc_test.doc-test-run-failure-list-empty)
        (doc_test.doc-test-join-advisories (& advisories-out)))]
    [outcome : check_cli.SelfhostCheckOutcome
      (check_cli.selfhost-check-outcome-from-doctest-report
        (text_buf.empty)
        report)]
    [framed : String
      (check_cli.selfhost-check-batch-format-entry 0 "docs/advisory.tl" outcome)]
    (and
      (match check-res
        [(No) true]
        [(Some _) false])
      (source_text.starts-with?
        (& framed)
        "CHECK_BATCH_ENTRY|0|0|1|5|docs/advisory.tl\nType checking passed!\n")
      (string.contains (& framed) "warning: unnecessary unsafe block")
      (string.contains (& framed) "docs/advisory.tl.doctest.0:1:22"))))

(define (main) : i64
  (unless
    (entry-selectors-restored? 42)
    (io.panic "test CLI entry state: entry-selectors-restored failed"))
  (unless
    (entry-bound-load-restored?)
    (io.panic "test CLI entry state: entry-bound-load-restored failed"))
  (unless
    (loader-cache-lifetime-ok?)
    (io.panic "test CLI entry state: loader-cache-lifetime failed"))
  (unless
    (check-batch-doctest-advisory-framing-ok?)
    (io.panic
      "test CLI entry state: check-batch-doctest-advisory-framing failed"))
  42)