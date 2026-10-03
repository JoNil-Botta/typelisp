;; Executable snapshot/edit planner conformance and the redundant-begin fix
;; round trip, discovered by inline-test CI.
(import compiler_diagnostic as diag)
(import lint_fix_plan_core as planner)
(import lint_core)
(import format_rules)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

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
          (candidate "a" source 2 4 "Z" CompilerDiagnosticMachineApplicable))
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
      (candidate "maybe" source 2 4 "Z" CompilerDiagnosticMaybeIncorrect)]
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
        [(ApplicabilityExcluded) true]
        [_ false])
      (not admitted.publishable)
      (match (array-ref admitted.outcomes.slots 0).reason
        [(StaleVersion) true]
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
            CompilerDiagnosticMachineApplicable))
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
            CompilerDiagnosticMachineApplicable))
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
            CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    (and
      (not utf.publishable)
      (match (array-ref utf.outcomes.slots 0).reason
        [(InvalidUtf8Boundary) true]
        [_ false])
      (not crlf.publishable)
      (match (array-ref crlf.outcomes.slots 0).reason
        [(InvalidUtf8Boundary) true]
        [_ false])
      (not rejected.publishable)
      (match (array-ref rejected.outcomes.slots 0).reason
        [(SyntheticSource) true]
        [_ false]))))

(define (permuted-edits-ok?) : bool
  (let
    [source : planner.LintFixSnapshot (planner.snapshot "a.tl" "abcdef" 7 true)]
    [early : planner.LintFixCandidate
      (candidate "z" (clone source) 2 3 "Z" CompilerDiagnosticMachineApplicable)]
    [late : planner.LintFixCandidate
      (candidate "a" (clone source) 5 6 "Y" CompilerDiagnosticMachineApplicable)]
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
      (candidate "a" (clone source) 2 4 "Z" CompilerDiagnosticMachineApplicable)]
    [second : planner.LintFixCandidate
      (candidate "b" (clone source) 3 5 "Y" CompilerDiagnosticMachineApplicable)]
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
            CompilerDiagnosticMachineApplicable))
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
            CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    [changed : planner.LintFixSnapshot
      (planner.snapshot "a.tl" "ABCDEF" 7 true)]
    [stale : planner.LintFixPlan
      (planner.plan
        (one-snapshot changed)
        (one-candidate
          (candidate "x" source 2 4 "Z" CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    (and
      (not overlap.publishable)
      (= overlap.edits.len 0)
      (match (array-ref overlap.outcomes.slots 0).reason
        [(OverlappingEdit) true]
        [_ false])
      (match (array-ref overlap.outcomes.slots 1).reason
        [(OverlappingEdit) true]
        [_ false])
      (not duplicate.publishable)
      (match (array-ref duplicate.outcomes.slots 0).reason
        [(DuplicateEdit) true]
        [_ false])
      (not same-id.publishable)
      (match (array-ref same-id.outcomes.slots 0).reason
        [(DuplicateCandidate) true]
        [_ false])
      (not stale.publishable)
      (match (array-ref stale.outcomes.slots 0).reason
        [(StaleSource) true]
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
            CompilerDiagnosticMachineApplicable
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
            CompilerDiagnosticMachineApplicable
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
            CompilerDiagnosticMachineApplicable)
          (candidate
            "right"
            (clone source)
            4
            6
            "R"
            CompilerDiagnosticMachineApplicable))
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
            CompilerDiagnosticMachineApplicable)
          (candidate
            "insert-b"
            (clone source)
            3
            3
            "Y"
            CompilerDiagnosticMachineApplicable))
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
            CompilerDiagnosticMachineApplicable)
          (candidate "outer" source 2 5 "Z" CompilerDiagnosticMachineApplicable))
        (planner.machine-only))]
    (and
      touching.publishable
      (string.eq (array-ref (planner.apply touching).slots 0).source "aLRf")
      (not same-position.publishable)
      (= same-position.edits.len 0)
      (match (array-ref same-position.outcomes.slots 0).reason
        [(OverlappingEdit) true]
        [_ false])
      (not nested.publishable)
      (match (array-ref nested.outcomes.slots 0).reason
        [(OverlappingEdit) true]
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
        CompilerDiagnosticMachineApplicable)]
    [missing : planner.LintFixCandidate
      (candidate
        "missing"
        (clone source)
        2
        3
        "Y"
        CompilerDiagnosticMachineApplicable)]
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
            [(MissingIdentity) true]
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

;; redundant-begin is the first rule with a machine-applicable fix: its
;; findings plan as one publishable batch, and the applied source has no
;; finding left and formats like hand-written multi-form bodies.
(define (redundant-begin-findings [source : String]) : lint_core.LintFindings
  (lint_core.lint-redundant-begin-scan source (lint_core.lint-findings-empty)))

(define (redundant-begin-plan [source : String]) : planner.LintFixPlan
  (let
    [findings : lint_core.LintFindings
      (redundant-begin-findings (clone source))]
    [count : i64 (lint_core.lint-findings-count (clone findings))]
    [snap : planner.LintFixSnapshot (planner.snapshot "fix.tl" source 1 true)]
    [slots : (__tl_dyn-array planner.LintFixCandidate)
      (__tl_make-array planner.LintFixCandidate count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [finding : lint_core.LintFinding
            (lint_core.lint-findings-ref (& findings) index)]
          (begin
            (match finding.fix
              [(lint_core.LintFixAvailable fix)
                (set!
                  (array-ref slots index)
                  (planner.LintFixCandidate
                    (str_cat.str-cat
                      "redundant-begin-"
                      (string.int->string index))
                    (diag.compiler-diagnostic-with-fix
                      (diag.compiler-diagnostic-from-ast-span
                        "fix.tl"
                        finding.span
                        finding.message)
                      fix)
                    (one-identity (planner.source-identity (clone snap)))))]
              [(lint_core.LintFixUnavailable _ _)
                (io.panic "redundant-begin finding without a fix")])
            (set! index (+ index 1)))))
      (planner.plan
        (one-snapshot snap)
        (planner.LintFixCandidateSeq slots count)
        (planner.machine-only)))))

(define (redundant-begin-applied [source : String]) : String
  (let
    [batch : planner.LintFixPlan (redundant-begin-plan source)]
    (begin
      (assert batch.publishable "redundant-begin fixes should plan cleanly")
      (clone (array-ref (planner.apply batch).slots 0).source))))

(define (formatted [source : String]) : String
  (match (format_rules.format-rules-render-source-width-result source 80)
    [(format_rules.ResultFormatString.Ok text) text]
    [(format_rules.ResultFormatString.Err _)
      (io.panic "redundant-begin fixed source should format")]))

(define (redundant-begin-round-trip-ok?
  [source : String]
  [findings : i64]
  [applied : String]
  [canonical : String]) : bool
  (let
    [fixed : String (redundant-begin-applied (clone source))]
    (and
      (=
        (lint_core.lint-findings-count (redundant-begin-findings source))
        findings)
      (string.eq fixed applied)
      (=
        (lint_core.lint-findings-count (redundant-begin-findings (clone fixed)))
        0)
      (string.eq (formatted fixed) canonical)
      (string.eq (formatted (clone canonical)) canonical))))

(test
  lint-redundant-begin-fix-round-trip
  (assert
    (redundant-begin-round-trip-ok?
      "(define (s) : unit
  unit)

(define (f [x : i64]) : i64
  (begin
    (set! x 1)
    x))

(define (g [x : i64]) : i64
  (match x
    [0
      (begin
        (s)
        1)]
    [_ (begin (s) x)]))

(define (h [x : i64]) : i64
  (cond
    [(= x 0) (begin (set! x 2) x)]
    [else x]))

(define (w [x : i64]) : unit
  (when
    (> x 0)
    (begin
      (set! x 1)
      (s))))

(test t
  (begin
    (s)
    (s)))
"
      6
      "(define (s) : unit
  unit)

(define (f [x : i64]) : i64
    (set! x 1)
    x)

(define (g [x : i64]) : i64
  (match x
    [0
        (s)
        1]
    [_ (s) x]))

(define (h [x : i64]) : i64
  (cond
    [(= x 0) (set! x 2) x]
    [else x]))

(define (w [x : i64]) : unit
  (when
    (> x 0)
      (set! x 1)
      (s)))

(test t
    (s)
    (s))
"
      "(define (s) : unit
  unit)

(define (f [x : i64]) : i64
  (set! x 1)
  x)

(define (g [x : i64]) : i64
  (match x
    [0
      (s)
      1]
    [_
      (s)
      x]))

(define (h [x : i64]) : i64
  (cond
    [(= x 0)
      (set! x 2)
      x]
    [else x]))

(define (w [x : i64]) : unit
  (when (> x 0) (set! x 1) (s)))

(test t (s) (s))")
    "lint redundant-begin fix round trip"))

(test
  lint-redundant-begin-nested-fixes-compose
  (assert
    (redundant-begin-round-trip-ok?
      "(define (n) : i64
  (let
    [x : i64 0]
    (begin
      (begin
        (set! x 1)
        (set! x 2))
      x)))
"
      2
      "(define (n) : i64
  (let
    [x : i64 0]
        (set! x 1)
        (set! x 2)
      x))
"
      "(define (n) : i64
  (let
    [x : i64 0]
    (set! x 1)
    (set! x 2)
    x))")
    "lint redundant-begin nested fixes"))

(test
  lint-redundant-begin-keeps-required-begins
  (assert
    (=
      (lint_core.lint-findings-count
        (redundant-begin-findings
          "(define (v) : i64
  1)

(define g : i64
  (begin (v) 2))

(define (test [a : i64] [b : i64]) : i64
  (+ a b))

(defstruct P (x i64))

(define (projected) : i64
  (let
    [p : i64 0]
    (begin (v) (P p)).x))

(define (k [x : i64]) : unit
  (let
    [y : i64 (begin (v) x)]
    (set! x (+ (begin (v) y) 1))
    (let [z : i64 0] (begin z))
    (when (> x 0) (begin (v) (set! x 1)))
    (unless (> x 0) (begin (when true (set! x 2)) (v) (set! x 3)))
    (set! x (test 1 (begin (v) 2)))
    (if (> x 0) (begin (v) unit) unit)))

(defmacro (quoted) : Expr
  `(begin
    (let [x : i64 1] '(begin x x))
    1))
"))
      0)
    "lint redundant-begin must keep required begins"))