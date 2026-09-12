;; Executable snapshot/edit planner conformance, discovered by inline-test CI.
(import compiler_diagnostic as diag)
(import lint_fix_plan_core as planner)
(import stdlib.io)
(import stdlib.string)

(define (assert [condition : bool] [message : String]) : unit
  (unless condition (io.panic message)))

(define (one-snapshot [value : planner.LintFixSnapshot]) : planner.LintFixSnapshotSeq
  (let
    [slots : (__tl_dyn-array planner.LintFixSnapshot)
      (__tl_make-array planner.LintFixSnapshot 1)]
    (begin
      (set! (array-ref slots 0) value)
      (planner.LintFixSnapshotSeq slots 1))))

(define (one-identity [value : planner.LintFixSourceIdentity]) : planner.LintFixSourceIdentitySeq
  (let
    [slots : (__tl_dyn-array planner.LintFixSourceIdentity)
      (__tl_make-array planner.LintFixSourceIdentity 1)]
    (begin
      (set! (array-ref slots 0) value)
      (planner.LintFixSourceIdentitySeq slots 1))))

(define (one-candidate [value : planner.LintFixCandidate]) : planner.LintFixCandidateSeq
  (let
    [slots : (__tl_dyn-array planner.LintFixCandidate)
      (__tl_make-array planner.LintFixCandidate 1)]
    (begin
      (set! (array-ref slots 0) value)
      (planner.LintFixCandidateSeq slots 1))))

(define (two-candidates
  [first : planner.LintFixCandidate]
  [second : planner.LintFixCandidate]) : planner.LintFixCandidateSeq
  (let
    [slots : (__tl_dyn-array planner.LintFixCandidate)
      (__tl_make-array planner.LintFixCandidate 2)]
    (begin
      (set! (array-ref slots 0) first)
      (set! (array-ref slots 1) second)
      (planner.LintFixCandidateSeq slots 2))))

(define (candidate
  [id : String]
  [source : planner.LintFixSnapshot]
  [start : i64]
  [end : i64]
  [replacement : String]
  [applicability : diag.CompilerDiagnosticApplicability]) : planner.LintFixCandidate
  (let
    [path : String (clone source.path)]
    [edit : diag.CompilerDiagnosticTextEdit
      (diag.compiler-diagnostic-text-edit-new
        (diag.CompilerDiagnosticSpan "" 1 start 1 end)
        replacement)]
    [fix : diag.CompilerDiagnosticFix
      (diag.compiler-diagnostic-fix-new
        "Replace"
        applicability
        (diag.compiler-diagnostic-text-edit-single edit))]
    [diagnostic : diag.CompilerDiagnostic
      (diag.compiler-diagnostic-with-fix
        (diag.compiler-diagnostic-simple path 1 1 "lint")
        fix)]
    (planner.LintFixCandidate
      id
      diagnostic
      (one-identity (planner.source-identity source)))))

(define (single-edit-ok?) : bool
  (let
    [source : planner.LintFixSnapshot
      (planner.snapshot "a.tl" "abcdef\n" 7 true)]
    [batch : planner.LintFixPlan
      (planner.plan
        (one-snapshot (clone source))
        (one-candidate
          (candidate
            "a"
            source
            2
            4
            "Z"
            diag.CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    [applied : planner.LintFixSnapshotSeq (planner.apply (clone batch))]
    (and
      batch.publishable
      (= batch.outcomes.len 1)
      (= batch.edits.len 1)
      (string.eq (array-ref applied.slots 0).source "aZdef\n"))))

(define (stale-and-uncertain-ok?) : bool
  (let
    [source : planner.LintFixSnapshot (planner.snapshot "a.tl" "abcdef" 7 true)]
    [stale : planner.LintFixSnapshot (planner.snapshot "a.tl" "abcdef" 8 true)]
    [candidate : planner.LintFixCandidate
      (candidate "maybe" source 2 4 "Z" diag.CompilerDiagnosticMaybeIncorrect)]
    [skipped : planner.LintFixPlan
      (planner.plan
        (one-snapshot (clone stale))
        (one-candidate (clone candidate))
        (planner.machine-only))]
    [admitted : planner.LintFixPlan
      (planner.plan
        (one-snapshot stale)
        (one-candidate candidate)
        (planner.LintFixPolicy true false false))]
    (and
      skipped.publishable
      (= skipped.edits.len 0)
      (match (array-ref skipped.outcomes.slots 0).reason
        [(planner.ApplicabilityExcluded) true]
        [_ false])
      (not admitted.publishable)
      (match (array-ref admitted.outcomes.slots 0).reason
        [(planner.StaleVersion) true]
        [_ false]))))

(define (invalid-boundaries-ok?) : bool
  (let
    [source : planner.LintFixSnapshot
      (planner.snapshot "unicode.tl" "é\r\nend" 0 true)]
    [utf : planner.LintFixPlan
      (planner.plan
        (one-snapshot (clone source))
        (one-candidate
          (candidate
            "utf"
            (clone source)
            2
            3
            "z"
            diag.CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    [crlf : planner.LintFixPlan
      (planner.plan
        (one-snapshot (clone source))
        (one-candidate
          (candidate
            "crlf"
            (clone source)
            4
            5
            "z"
            diag.CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    [synthetic : planner.LintFixSnapshot
      (planner.snapshot "unicode.tl" "é\r\nend" 0 false)]
    [rejected : planner.LintFixPlan
      (planner.plan
        (one-snapshot synthetic)
        (one-candidate
          (candidate
            "synthetic"
            source
            1
            3
            "z"
            diag.CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    (and
      (not utf.publishable)
      (match (array-ref utf.outcomes.slots 0).reason
        [(planner.InvalidUtf8Boundary) true]
        [_ false])
      (not crlf.publishable)
      (match (array-ref crlf.outcomes.slots 0).reason
        [(planner.InvalidUtf8Boundary) true]
        [_ false])
      (not rejected.publishable)
      (match (array-ref rejected.outcomes.slots 0).reason
        [(planner.SyntheticSource) true]
        [_ false]))))

(define (permuted-edits-ok?) : bool
  (let
    [source : planner.LintFixSnapshot (planner.snapshot "a.tl" "abcdef" 7 true)]
    [early : planner.LintFixCandidate
      (candidate
        "z"
        (clone source)
        2
        3
        "Z"
        diag.CompilerDiagnosticMachineApplicable)]
    [late : planner.LintFixCandidate
      (candidate
        "a"
        (clone source)
        5
        6
        "Y"
        diag.CompilerDiagnosticMachineApplicable)]
    [forward : planner.LintFixPlan
      (planner.plan
        (one-snapshot (clone source))
        (two-candidates (clone early) (clone late))
        (planner.machine-only))]
    [backward : planner.LintFixPlan
      (planner.plan
        (one-snapshot source)
        (two-candidates late early)
        (planner.machine-only))]
    [forward-text : String
      (clone (array-ref (planner.apply (clone forward)).slots 0).source)]
    [backward-text : String
      (clone (array-ref (planner.apply (clone backward)).slots 0).source)]
    (and
      forward.publishable
      backward.publishable
      (= forward.edits.len 2)
      (= backward.edits.len 2)
      (string.eq forward-text "aZcdYf")
      (string.eq forward-text backward-text)
      (string.eq (array-ref forward.outcomes.slots 0).id "a")
      (string.eq (array-ref backward.outcomes.slots 0).id "a"))))

(define (conflicts-and-hash-ok?) : bool
  (let
    [source : planner.LintFixSnapshot (planner.snapshot "a.tl" "abcdef" 7 true)]
    [first : planner.LintFixCandidate
      (candidate
        "a"
        (clone source)
        2
        4
        "Z"
        diag.CompilerDiagnosticMachineApplicable)]
    [second : planner.LintFixCandidate
      (candidate
        "b"
        (clone source)
        3
        5
        "Y"
        diag.CompilerDiagnosticMachineApplicable)]
    [overlap : planner.LintFixPlan
      (planner.plan
        (one-snapshot (clone source))
        (two-candidates (clone first) second)
        (planner.machine-only))]
    [duplicate : planner.LintFixPlan
      (planner.plan
        (one-snapshot (clone source))
        (two-candidates
          (clone first)
          (candidate
            "b"
            (clone source)
            2
            4
            "Z"
            diag.CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    [same-id : planner.LintFixPlan
      (planner.plan
        (one-snapshot (clone source))
        (two-candidates
          first
          (candidate
            "a"
            (clone source)
            5
            6
            "Y"
            diag.CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    [changed : planner.LintFixSnapshot
      (planner.snapshot "a.tl" "ABCDEF" 7 true)]
    [stale : planner.LintFixPlan
      (planner.plan
        (one-snapshot changed)
        (one-candidate
          (candidate
            "x"
            source
            2
            4
            "Z"
            diag.CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    (and
      (not overlap.publishable)
      (= overlap.edits.len 0)
      (match (array-ref overlap.outcomes.slots 0).reason
        [(planner.OverlappingEdit) true]
        [_ false])
      (match (array-ref overlap.outcomes.slots 1).reason
        [(planner.OverlappingEdit) true]
        [_ false])
      (not duplicate.publishable)
      (match (array-ref duplicate.outcomes.slots 0).reason
        [(planner.DuplicateEdit) true]
        [_ false])
      (not same-id.publishable)
      (match (array-ref same-id.outcomes.slots 0).reason
        [(planner.DuplicateCandidate) true]
        [_ false])
      (not stale.publishable)
      (match (array-ref stale.outcomes.slots 0).reason
        [(planner.StaleSource) true]
        [_ false]))))

(define (multi-file-and-large-fix-ok?) : bool
  (let
    [a : planner.LintFixSnapshot (planner.snapshot "a.tl" "abc" 7 true)]
    [b : planner.LintFixSnapshot (planner.snapshot "b.tl" "def" 8 true)]
    [snapshots : (__tl_dyn-array planner.LintFixSnapshot)
      (__tl_make-array planner.LintFixSnapshot 2)]
    [identities : (__tl_dyn-array planner.LintFixSourceIdentity)
      (__tl_make-array planner.LintFixSourceIdentity 2)]
    [edits : (__tl_dyn-array diag.CompilerDiagnosticTextEdit)
      (__tl_make-array diag.CompilerDiagnosticTextEdit 2)]
    (begin
      (set! (array-ref snapshots 0) (clone a))
      (set! (array-ref snapshots 1) (clone b))
      ;; Deliberately reverse identities: outcome metadata belongs to a.tl.
      (set! (array-ref identities 0) (planner.source-identity b))
      (set! (array-ref identities 1) (planner.source-identity (clone a)))
      (set!
        (array-ref edits 0)
        (diag.compiler-diagnostic-text-edit-new
          (diag.CompilerDiagnosticSpan "" 1 1 1 2)
          "A"))
      (set!
        (array-ref edits 1)
        (diag.compiler-diagnostic-text-edit-new
          (diag.CompilerDiagnosticSpan "b.tl" 1 2 1 3)
          "E"))
      (let
        [fix : diag.CompilerDiagnosticFix
          (diag.compiler-diagnostic-fix-new
            "Two files"
            diag.CompilerDiagnosticMachineApplicable
            (diag.CompilerDiagnosticTextEditSeq edits 2))]
        [candidate : planner.LintFixCandidate
          (planner.LintFixCandidate
            "two-files"
            (diag.compiler-diagnostic-with-fix
              (diag.compiler-diagnostic-simple "a.tl" 1 1 "lint")
              fix)
            (planner.LintFixSourceIdentitySeq identities 2))]
        [plan : planner.LintFixPlan
          (planner.plan
            (planner.LintFixSnapshotSeq snapshots 2)
            (one-candidate candidate)
            (planner.machine-only))]
        [applied : planner.LintFixSnapshotSeq (planner.apply (clone plan))]
        (and
          plan.publishable
          (= plan.edits.len 2)
          (= (array-ref plan.outcomes.slots 0).version 7)
          (= (array-ref plan.outcomes.slots 0).source-hash a.source-hash)
          (string.eq (array-ref applied.slots 0).source "Abc")
          (string.eq (array-ref applied.slots 1).source "dEf"))))))

(define (many-edits-ok?) : bool
  (let
    [source : planner.LintFixSnapshot
      (planner.snapshot "many.tl" "aaaaaaaaaaaaaaaaa" 1 true)]
    [edits : (__tl_dyn-array diag.CompilerDiagnosticTextEdit)
      (__tl_make-array diag.CompilerDiagnosticTextEdit 17)]
    [at : i64 0]
    (begin
      (while (< at 17)
        (begin
          (set!
            (array-ref edits at)
            (diag.compiler-diagnostic-text-edit-new
              (diag.CompilerDiagnosticSpan "" 1 (+ at 1) 1 (+ at 2))
              "b"))
          (set! at (+ at 1))))
      (let
        [fix : diag.CompilerDiagnosticFix
          (diag.compiler-diagnostic-fix-new
            "Seventeen edits"
            diag.CompilerDiagnosticMachineApplicable
            (diag.CompilerDiagnosticTextEditSeq edits 17))]
        [candidate : planner.LintFixCandidate
          (planner.LintFixCandidate
            "many"
            (diag.compiler-diagnostic-with-fix
              (diag.compiler-diagnostic-simple "many.tl" 1 1 "lint")
              fix)
            (one-identity (planner.source-identity (clone source))))]
        [plan : planner.LintFixPlan
          (planner.plan
            (one-snapshot source)
            (one-candidate candidate)
            (planner.machine-only))]
        [applied : planner.LintFixSnapshotSeq (planner.apply (clone plan))]
        (and
          plan.publishable
          (= plan.edits.len 17)
          (string.eq (array-ref applied.slots 0).source "bbbbbbbbbbbbbbbbb"))))))

(define (touching-and-inserts-ok?) : bool
  (let
    [source : planner.LintFixSnapshot
      (planner.snapshot "touch.tl" "abcdef" 3 true)]
    [touching : planner.LintFixPlan
      (planner.plan
        (one-snapshot (clone source))
        (two-candidates
          (candidate
            "left"
            (clone source)
            2
            4
            "L"
            diag.CompilerDiagnosticMachineApplicable)
          (candidate
            "right"
            (clone source)
            4
            6
            "R"
            diag.CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    [same-position : planner.LintFixPlan
      (planner.plan
        (one-snapshot (clone source))
        (two-candidates
          (candidate
            "insert-a"
            (clone source)
            3
            3
            "X"
            diag.CompilerDiagnosticMachineApplicable)
          (candidate
            "insert-b"
            (clone source)
            3
            3
            "Y"
            diag.CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    [nested : planner.LintFixPlan
      (planner.plan
        (one-snapshot (clone source))
        (two-candidates
          (candidate
            "insert"
            (clone source)
            3
            3
            "X"
            diag.CompilerDiagnosticMachineApplicable)
          (candidate
            "outer"
            source
            2
            5
            "Z"
            diag.CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    (and
      touching.publishable
      (string.eq (array-ref (planner.apply touching).slots 0).source "aLRf")
      (not same-position.publishable)
      (= same-position.edits.len 0)
      (match (array-ref same-position.outcomes.slots 0).reason
        [(planner.OverlappingEdit) true]
        [_ false])
      (not nested.publishable)
      (match (array-ref nested.outcomes.slots 0).reason
        [(planner.OverlappingEdit) true]
        [_ false]))))

(define (missing-identity-and-atomicity-ok?) : bool
  (let
    [source : planner.LintFixSnapshot (planner.snapshot "a.tl" "abc" 1 true)]
    [valid : planner.LintFixCandidate
      (candidate
        "valid"
        (clone source)
        1
        2
        "X"
        diag.CompilerDiagnosticMachineApplicable)]
    [missing : planner.LintFixCandidate
      (candidate
        "missing"
        (clone source)
        2
        3
        "Y"
        diag.CompilerDiagnosticMachineApplicable)]
    (begin
      (set!
        missing.sources
        (planner.LintFixSourceIdentitySeq
          (__tl_make-array planner.LintFixSourceIdentity 0)
          0))
      (let
        [plan : planner.LintFixPlan
          (planner.plan
            (one-snapshot source)
            (two-candidates missing valid)
            (planner.machine-only))]
        [applied : planner.LintFixSnapshotSeq (planner.apply (clone plan))]
        (and
          (not plan.publishable)
          (= plan.edits.len 1)
          (string.eq (array-ref applied.slots 0).source "abc")
          (match (array-ref plan.outcomes.slots 0).reason
            [(planner.MissingIdentity) true]
            [_ false]))))))

(test
  lint-fix-plan-single-edit
  (assert (single-edit-ok?) "lint fix plan single edit"))

(test
  lint-fix-plan-stale-and-uncertain
  (assert (stale-and-uncertain-ok?) "lint fix plan stale and applicability"))

(test
  lint-fix-plan-invalid-boundaries
  (assert (invalid-boundaries-ok?) "lint fix plan UTF-8/CRLF/synthetic"))

(test
  lint-fix-plan-permuted-edits
  (assert (permuted-edits-ok?) "lint fix plan deterministic order"))

(test
  lint-fix-plan-conflicts-and-hash
  (assert (conflicts-and-hash-ok?) "lint fix plan conflicts/source identity"))

(test
  lint-fix-plan-multi-file
  (assert (multi-file-and-large-fix-ok?) "lint fix plan multi-file"))

(test
  lint-fix-plan-many-edits
  (assert (many-edits-ok?) "lint fix plan arbitrary edit count"))

(test
  lint-fix-plan-touching-and-inserts
  (assert (touching-and-inserts-ok?) "lint fix plan touching/nested/inserts"))

(test
  lint-fix-plan-atomicity
  (assert
    (missing-identity-and-atomicity-ok?)
    "lint fix plan missing identity/atomicity"))