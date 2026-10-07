;# Pure, snapshot-bound composition of shared compiler-diagnostic lint edits.
;#
;# This module never probes or writes a filesystem. A batch executor must reject
;# publication unless `publishable` is true, then recheck the same source
;# identities before a separate transactional write (#7280).
(import stdlib.iterator)
(import compiler_diagnostic as diag)
(import stdlib.hash)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(defstruct LintFixSnapshot
  (path String)
  (source String)
  (version i64)
  (source-hash i64)
  (editable bool))

(defstruct LintFixSnapshotSeq
  (slots (__tl_dyn-array LintFixSnapshot))
  (len i64))

;: A candidate pins each touched source, not just its primary diagnostic file.
(defstruct LintFixSourceIdentity
  (path String)
  (version i64)
  (source-hash i64))

(defstruct LintFixSourceIdentitySeq
  (slots (__tl_dyn-array LintFixSourceIdentity))
  (len i64))

(defstruct LintFixCandidate
  (id String)
  (diagnostic diag.CompilerDiagnostic)
  (sources LintFixSourceIdentitySeq))

(defstruct LintFixCandidateSeq
  (slots (__tl_dyn-array LintFixCandidate))
  (len i64))

(defstruct LintFixPolicy
  (maybe-incorrect bool)
  (has-placeholders bool)
  (unspecified bool))

(define (machine-only) : LintFixPolicy
  (LintFixPolicy false false false))

(defenum LintFixOutcomeKind
  (Planned)
  (Skipped)
  (Stale)
  (Invalid)
  (Conflicting))

;: Closed reason codes are stable event vocabulary for #6952/#7280. An
;: intentionally excluded applicability is not a failed admitted batch.
(defenum LintFixReason
  (None)
  (ApplicabilityExcluded)
  (MissingIdentity)
  (MissingSnapshot)
  (StaleVersion)
  (StaleSource)
  (SyntheticSource)
  (InvalidFix)
  (InvalidCoordinate)
  (InvalidUtf8Boundary)
  (DuplicateCandidate)
  (DuplicateEdit)
  (OverlappingEdit))

(defstruct LintFixOutcome
  (id String)
  (fix-index i64)
  (path String)
  (version i64)
  (source-hash i64)
  (applicability diag.CompilerDiagnosticApplicability)
  (kind LintFixOutcomeKind)
  (reason LintFixReason))

(defstruct LintFixOutcomeSeq
  (slots (__tl_dyn-array LintFixOutcome))
  (len i64))

(defstruct LintFixResolvedEdit
  (path String)
  (start i64)
  (end i64)
  (replacement String)
  (outcome-index i64))

(defstruct LintFixResolvedEditSeq
  (slots (__tl_dyn-array LintFixResolvedEdit))
  (len i64))

(defstruct LintFixPlan
  (snapshots LintFixSnapshotSeq)
  (outcomes LintFixOutcomeSeq)
  (edits LintFixResolvedEditSeq)
  (publishable bool))

(defenum LintFixOffset
  (ValidOffset i64)
  (BadCoordinate)
  (BadUtf8Boundary))

(defenum LintFixEditCheck
  (ValidEdit LintFixResolvedEdit)
  (RejectedEdit LintFixOutcomeKind LintFixReason))

(define (snapshot
  [path : String]
  [source : String]
  [version : i64]
  [editable : bool]) : LintFixSnapshot
  (let
    [content-hash : i64 (hash.string-key (& source))]
    (LintFixSnapshot path source version content-hash editable)))

(define (source-identity [source : LintFixSnapshot]) : LintFixSourceIdentity
  (LintFixSourceIdentity source.path source.version source.source-hash))

(define (source-index [snapshots : LintFixSnapshotSeq] [path : String]) : i64
  (let
    [index : i64 0]
    (while (and
      (< index snapshots.len)
      (not (string.eq (array-ref snapshots.slots index).path path)))
      (+= index 1))
    (if (< index snapshots.len)
      index
      -1)))

(define (identity-index [identities : LintFixSourceIdentitySeq] [path : String]) : i64
  (let
    [index : i64 0]
    (while (and
      (< index identities.len)
      (not (string.eq (array-ref identities.slots index).path path)))
      (+= index 1))
    (if (< index identities.len)
      index
      -1)))

(define (applicability-admitted?
  [value : diag.CompilerDiagnosticApplicability]
  [policy : LintFixPolicy]) : bool
  (match value
    [(CompilerDiagnosticMachineApplicable) true]
    [(CompilerDiagnosticMaybeIncorrect) policy.maybe-incorrect]
    [(CompilerDiagnosticHasPlaceholders) policy.has-placeholders]
    [(CompilerDiagnosticUnspecified) policy.unspecified]))

;: The compiler's edit columns count UTF-8 bytes. Reject a continuation byte
;: boundary and the middle of CRLF; neither is an editable character boundary.
(define (offset-at [source : String] [wanted-line : i64] [wanted-col : i64]) : LintFixOffset
  (if (or (<= wanted-line 0) (<= wanted-col 0))
    (BadCoordinate)
    (let
      [length : i64 (string.string-length source)]
      [offset : i64 0]
      [line : i64 1]
      [col : i64 1]
      [found : bool false]
      (while (and (not found) (<= offset length))
        (if (and (= line wanted-line) (= col wanted-col))
          (set! found true)
          (if (= offset length)
            (set! offset (+ length 1))
            (let
              [byte : char (string.string-ref source offset)]
              (if (= byte '\n')
                (begin
                  (+= line 1)
                  (set! col 1))
                (+= col 1))
              (+= offset 1)))))
      (if (not found)
        (BadCoordinate)
        (if (and
          (< offset length)
          (or
            (= (bit-and (cast (string.string-ref source offset) : i64) 192) 128)
            (and
              (> offset 0)
              (= (string.string-ref source (- offset 1)) '\r')
              (= (string.string-ref source offset) '\n'))))
          (BadUtf8Boundary)
          (ValidOffset offset))))))

(define (check-edit
  [snapshots : LintFixSnapshotSeq]
  [candidate : LintFixCandidate]
  [edit : diag.CompilerDiagnosticTextEdit]
  [outcome-index : i64]) : LintFixEditCheck
  (let
    [primary-path : String (diag.compiler-diagnostic-path candidate.diagnostic)]
    [path : String
      (diag.compiler-diagnostic-edit-effective-path primary-path (clone edit))]
    [snapshot-index : i64 (source-index (clone snapshots) (clone path))]
    [identity-at : i64 (identity-index (clone candidate.sources) (clone path))]
    (cond
      [(or (string.eq path "") (< identity-at 0))
        (RejectedEdit (Invalid) (MissingIdentity))]
      [(< snapshot-index 0) (RejectedEdit (Invalid) (MissingSnapshot))]
      [else
        (let
          [source : LintFixSnapshot
            (clone (array-ref snapshots.slots snapshot-index))]
          [identity : LintFixSourceIdentity
            (clone (array-ref candidate.sources.slots identity-at))]
          [span : diag.CompilerDiagnosticSpan edit.span]
          (cond
            [(not source.editable) (RejectedEdit (Invalid) (SyntheticSource))]
            [(not (= source.version identity.version))
              (RejectedEdit (Stale) (StaleVersion))]
            [(or
                (not (= source.source-hash identity.source-hash))
                (not (= source.source-hash (hash.string-key (& source.source)))))
              (RejectedEdit (Stale) (StaleSource))]
            [else
              (match (offset-at
                (clone source.source)
                (diag.compiler-diagnostic-span-start-line span)
                (diag.compiler-diagnostic-span-start-col span))
                [(BadCoordinate) (RejectedEdit (Invalid) (InvalidCoordinate))]
                [(BadUtf8Boundary)
                  (RejectedEdit (Invalid) (InvalidUtf8Boundary))]
                [(ValidOffset start)
                  (match (offset-at
                    source.source
                    (diag.compiler-diagnostic-span-end-line span)
                    (diag.compiler-diagnostic-span-end-col span))
                    [(BadCoordinate)
                      (RejectedEdit (Invalid) (InvalidCoordinate))]
                    [(BadUtf8Boundary)
                      (RejectedEdit (Invalid) (InvalidUtf8Boundary))]
                    [(ValidOffset end)
                      (if (or
                        (> start end)
                        (and (= start end) (string.eq edit.replacement "")))
                        (RejectedEdit (Invalid) (InvalidCoordinate))
                        (ValidEdit
                          (LintFixResolvedEdit
                            path
                            start
                            end
                            edit.replacement
                            outcome-index)))])])]))])))

(define (edits-overlap?
  [left : LintFixResolvedEdit]
  [right : LintFixResolvedEdit]) : bool
  (and
    (string.eq left.path right.path)
    (or
      (and
        (= left.start right.start)
        (or (= left.start left.end) (= right.start right.end)))
      (and
        (= left.start left.end)
        (= right.start right.end)
        (= left.start right.start))
      (and (< left.start right.end) (< right.start left.end))
      (and
        (= left.start left.end)
        (< right.start left.start)
        (< left.start right.end))
      (and
        (= right.start right.end)
        (< left.start right.start)
        (< right.start left.end)))))

(define (same-edit? [left : LintFixResolvedEdit] [right : LintFixResolvedEdit]) : bool
  (and
    (string.eq left.path right.path)
    (= left.start right.start)
    (= left.end right.end)
    (string.eq left.replacement right.replacement)))

(define (edit-before?
  [left : LintFixResolvedEdit]
  [right : LintFixResolvedEdit]) : bool
  (if (string.eq left.path right.path)
    (> left.start right.start)
    (string-before? left.path right.path)))

(define (string-before? [left : String] [right : String]) : bool
  (let
    [left-length : i64 (string.string-length left)]
    [right-length : i64 (string.string-length right)]
    [limit : i64
      (if (< left-length right-length)
        left-length
        right-length)]
    [index : i64 0]
    (while (and
      (< index limit)
      (= (string.string-ref left index) (string.string-ref right index)))
      (+= index 1))
    (if (= index limit)
      (< left-length right-length)
      (< (string.string-ref left index) (string.string-ref right index)))))

(define (ordered-candidates [candidates : LintFixCandidateSeq]) : LintFixCandidateSeq
  (let
    [slots : (__tl_dyn-array LintFixCandidate)
      (__tl_make-array LintFixCandidate candidates.len)]
    (for [index (iterator.range 0 candidates.len)]
      (set! (array-ref slots index) (clone (array-ref candidates.slots index))))
    (for [index (iterator.range 1 candidates.len)]
      (let
        [at : i64 index]
        (while (and
          (> at 0)
          (string-before?
            (clone (array-ref slots at).id)
            (clone (array-ref slots (- at 1)).id)))
          (let
            [earlier : LintFixCandidate (clone (array-ref slots (- at 1)))]
            (set! (array-ref slots (- at 1)) (clone (array-ref slots at)))
            (set! (array-ref slots at) earlier)
            (-= at 1)))))
    (LintFixCandidateSeq slots candidates.len)))

(define (candidate-fix-count [candidates : LintFixCandidateSeq]) : i64
  (let
    [total : i64 0]
    (for [index (iterator.range 0 candidates.len)]
      (set!
        total
        (+
          total
          (diag.compiler-diagnostic-fixes
            (& (array-ref candidates.slots index).diagnostic)).len)))
    total))

(define (candidate-edit-count [candidates : LintFixCandidateSeq]) : i64
  (let
    [total : i64 0]
    (for [candidate-at (iterator.range 0 candidates.len)]
      (let
        [fixes : diag.CompilerDiagnosticFixSeq
          (diag.compiler-diagnostic-fixes
            (& (array-ref candidates.slots candidate-at).diagnostic))]
        (for [fix-at (iterator.range 0 fixes.len)]
          (set! total (+ total (array-ref fixes.slots fix-at).edits.len)))))
    total))

;: Plan all candidates, then mark both sides of every cross-fix conflict.
;: There is deliberately no input-order winner for a conflicting batch.
(define (plan
  [snapshots : LintFixSnapshotSeq]
  [candidates : LintFixCandidateSeq]
  [policy : LintFixPolicy]) : LintFixPlan
  (let
    [ordered : LintFixCandidateSeq (ordered-candidates candidates)]
    [maximum : i64 (candidate-fix-count (clone ordered))]
    [maximum-edits : i64 (candidate-edit-count (clone ordered))]
    [outcomes : (__tl_dyn-array LintFixOutcome)
      (__tl_make-array LintFixOutcome maximum)]
    [edits : (__tl_dyn-array LintFixResolvedEdit)
      (__tl_make-array LintFixResolvedEdit maximum-edits)]
    [outcome-count : i64 0]
    [edit-count : i64 0]
    (for [candidate-at (iterator.range 0 ordered.len)]
      (let
        [candidate : LintFixCandidate
          (clone (array-ref ordered.slots candidate-at))]
        [fixes : diag.CompilerDiagnosticFixSeq
          (diag.compiler-diagnostic-fixes (& candidate.diagnostic))]
        (for [fix-at (iterator.range 0 fixes.len)]
          (let
            [fix : diag.CompilerDiagnosticFix
              (clone (array-ref fixes.slots fix-at))]
            [applicability : diag.CompilerDiagnosticApplicability
              (diag.compiler-diagnostic-fix-applicability (clone fix))]
            [first-edit : i64 edit-count]
            [reason : LintFixReason (None)]
            [kind : LintFixOutcomeKind (Planned)]
            [edit-at : i64 0]
            (cond
              [(not (applicability-admitted? applicability policy))
                (set! kind (Skipped))
                (set! reason (ApplicabilityExcluded))]
              [(or
                (string.eq candidate.id "")
                (string.eq
                  (diag.compiler-diagnostic-path candidate.diagnostic)
                  "")
                (not
                  (diag.compiler-diagnostic-span-valid-for-edit?
                    (diag.compiler-diagnostic-primary-span
                      (& candidate.diagnostic))))
                (not
                  (diag.compiler-diagnostic-fix-valid?
                    (diag.compiler-diagnostic-path candidate.diagnostic)
                    (clone fix))))
                (set! kind (Invalid))
                (set! reason (InvalidFix))]
              [else
                (while (and (= reason (None)) (< edit-at fix.edits.len))
                  (match (check-edit
                    (clone snapshots)
                    (clone candidate)
                    (clone (array-ref fix.edits.slots edit-at))
                    outcome-count)
                    [(ValidEdit resolved)
                      (for [prior (iterator.range first-edit edit-count)]
                        (when
                          (edits-overlap?
                            (clone resolved)
                            (clone (array-ref edits prior)))
                          (set! kind (Invalid))
                          (set! reason (InvalidFix))))
                      (when
                        (= kind (Planned))
                        (set! (array-ref edits edit-count) resolved)
                        (+= edit-count 1))]
                    [(RejectedEdit rejected-kind rejected-reason)
                      (set! kind rejected-kind)
                      (set! reason rejected-reason)])
                  (+= edit-at 1))])
            (if (not (= kind (Planned)))
              (set! edit-count first-edit)
              unit)
            (let
              [primary : i64
                (identity-index
                  (clone candidate.sources)
                  (diag.compiler-diagnostic-path candidate.diagnostic))]
              (set!
                (array-ref outcomes outcome-count)
                (LintFixOutcome
                  candidate.id
                  fix-at
                  (diag.compiler-diagnostic-path candidate.diagnostic)
                  (if (>= primary 0)
                    (array-ref candidate.sources.slots primary).version
                    -1)
                  (if (>= primary 0)
                    (array-ref candidate.sources.slots primary).source-hash
                    0)
                  applicability
                  kind
                  reason)))
            (+= outcome-count 1)))))
    (lint-fix-finish-plan snapshots outcomes outcome-count edits edit-count)))

;: Mark all conflicting owners symmetrically, compact only valid edits, and
;: sort by path and descending offset for deterministic in-memory application.
(define (lint-fix-finish-plan
  [snapshots : LintFixSnapshotSeq]
  [outcomes : (__tl_dyn-array LintFixOutcome)]
  [outcome-count : i64]
  [edits : (__tl_dyn-array LintFixResolvedEdit)]
  [edit-count : i64]) : LintFixPlan
  (let
    [publishable : bool true]
    [next-edits : (__tl_dyn-array LintFixResolvedEdit)
      (__tl_make-array LintFixResolvedEdit edit-count)]
    [next-count : i64 0]
    (for [left (iterator.range 0 edit-count)]
      (for [right (iterator.range (+ left 1) edit-count)]
        (let
          [one : LintFixResolvedEdit (clone (array-ref edits left))]
          [two : LintFixResolvedEdit (clone (array-ref edits right))]
          (if (and
            (not (= one.outcome-index two.outcome-index))
            (edits-overlap? (clone one) (clone two)))
            (let
              [reason : LintFixReason
                (if (same-edit? (clone one) (clone two))
                  (DuplicateEdit)
                  (OverlappingEdit))]
              [a : LintFixOutcome
                (clone (array-ref outcomes one.outcome-index))]
              [b : LintFixOutcome
                (clone (array-ref outcomes two.outcome-index))]
              (set! a.kind (Conflicting))
              (when
                (or
                  (not (= a.reason (OverlappingEdit)))
                  (= reason (OverlappingEdit)))
                (set! a.reason reason))
              (set! b.kind (Conflicting))
              (when
                (or
                  (not (= b.reason (OverlappingEdit)))
                  (= reason (OverlappingEdit)))
                (set! b.reason reason))
              (set! (array-ref outcomes one.outcome-index) a)
              (set! (array-ref outcomes two.outcome-index) b))
            unit))))
    ;; Duplicate stable identities cannot represent two independent fixes.
    (for [left (iterator.range 0 outcome-count)]
      (for [right (iterator.range (+ left 1) outcome-count)]
        (let
          [a : LintFixOutcome (clone (array-ref outcomes left))]
          [b : LintFixOutcome (clone (array-ref outcomes right))]
          (when
            (and (string.eq a.id b.id) (= a.fix-index b.fix-index))
            (set! a.kind (Invalid))
            (set! a.reason (DuplicateCandidate))
            (set! b.kind (Invalid))
            (set! b.reason (DuplicateCandidate))
            (set! (array-ref outcomes left) a)
            (set! (array-ref outcomes right) b)))))
    (for [left (iterator.range 0 edit-count)]
      (let
        [edit : LintFixResolvedEdit (clone (array-ref edits left))]
        (match (array-ref outcomes edit.outcome-index).kind
          [(Planned)
            (set! (array-ref next-edits next-count) edit)
            (+= next-count 1)]
          [_ unit])))
    (for [left (iterator.range 1 next-count)]
      (let
        [at : i64 left]
        (while (and
          (> at 0)
          (edit-before?
            (clone (array-ref next-edits at))
            (clone (array-ref next-edits (- at 1)))))
          (let
            [earlier : LintFixResolvedEdit
              (clone (array-ref next-edits (- at 1)))]
            (set!
              (array-ref next-edits (- at 1))
              (clone (array-ref next-edits at)))
            (set! (array-ref next-edits at) earlier)
            (-= at 1)))))
    (for [left (iterator.range 0 outcome-count)]
      (match (array-ref outcomes left).kind
        [(Invalid) (set! publishable false)]
        [(Stale) (set! publishable false)]
        [(Conflicting) (set! publishable false)]
        [_ unit]))
    (LintFixPlan
      snapshots
      (LintFixOutcomeSeq outcomes outcome-count)
      (LintFixResolvedEditSeq next-edits next-count)
      publishable)))

;: Apply only an entirely valid admitted batch. A skipped less-certain fix is
;: harmless; an invalid/stale/conflicting admitted fix blocks all mutation.
(define (apply [planned : LintFixPlan]) : LintFixSnapshotSeq
  (let
    [output : (__tl_dyn-array LintFixSnapshot)
      (__tl_make-array LintFixSnapshot planned.snapshots.len)]
    (for [source-at (iterator.range 0 planned.snapshots.len)]
      (let
        [original : LintFixSnapshot
          (clone (array-ref planned.snapshots.slots source-at))]
        [text : String original.source]
        (if planned.publishable
          (for [edit-at (iterator.range 0 planned.edits.len)]
            (let
              [edit : LintFixResolvedEdit
                (clone (array-ref planned.edits.slots edit-at))]
              (when
                (string.eq edit.path original.path)
                (set!
                  text
                  (str_cat.str-cat
                    (string.substring text 0 edit.start)
                    edit.replacement
                    (string.substring
                      text
                      edit.end
                      (- (string.string-length text) edit.end)))))))
          unit)
        (set!
          (array-ref output source-at)
          (snapshot original.path text original.version original.editable))))
    (LintFixSnapshotSeq output planned.snapshots.len)))