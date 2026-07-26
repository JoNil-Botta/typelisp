;# work-queue-chooser/chooser.tl - TypeLisp work-queue chooser.
;#
;# Reads the combined `{"prs":[...],"issues":[...]}` JSON from stdin, classifies
;# each entry, skips draft PRs, PRs whose checks are still pending/running, PRs
;# whose newest review/comment is later than their newest commit, issues labeled
;# `blocked`, and issues an open PR already claims (the issue number appears as a
;# 4+ digit run in a PR branch name or title -- an issue someone is already
;# working is not work to hand to a second agent), weights the rest (PR review =
;# 45,
;# ready-for-implementation = 10, research/triage = 1, +50 for a p0 label,
;# +3 for a p1 label), uses system entropy to make a weighted pick, and prints
;# one action line:
;#
;#   review pr #N: Title
;#   implement issue #N: Title
;#   research/triage issue #N: Title
;#
;# When the snapshot already holds more than 3 open non-draft PRs the review
;# queue is saturated, so ready-for-implementation issues are dropped from the
;# candidate pool and only review/research-triage actions stay eligible. This
;# bakes the orchestrator's "don't start new implementations while PRs pile up"
;# rule into the chooser instead of leaving it to the caller to re-roll.
;#
;# Selection uses host entropy through `stdlib/random.tl`; JSON parsing uses
;# `stdlib/json.tl`.
;#
;# Usage: `typelisp run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib`
(import stdlib.json)
(import stdlib.io)
(import stdlib.random)
(import stdlib.string)
(import stdlib.test)

;: Kind tags: 0 = PR (review), 1 = ready-for-implementation issue (implement),
;: 2 = research/triage issue.
(define kind-pr : i64
  0)
(define kind-ready : i64
  1)
(define kind-triage : i64
  2)
(define review-weight : i64
  45)
(define implement-weight : i64
  10)
(define research-weight : i64
  1)
(define p0-priority-bonus : i64
  50)
(define p1-priority-bonus : i64
  3)

;: When the snapshot holds more than this many open non-draft PRs, the review
;: queue is saturated: ready-for-implementation issues are dropped so the chooser
;: only yields review and research/triage actions. Draft PRs do not count.
(define implement-pr-cap : i64
  3)

;: A classified work-queue candidate carrying its display fields and weight.
(defstruct Candidate
  (kind i64)
  (number i64)
  (title String)
  (weight i64))

;: Immutable contiguous candidates in source order (PRs first, then issues).
(defstruct CandSeq
  (slots (Array Candidate))
  (len i64))

;: Capacity-doubling builder that appends candidates in source order.
(defstruct CandBuilder
  (slots (Array Candidate))
  (len i64))

(define (cand-builder-new) : CandBuilder
  (CandBuilder (make-array Candidate 4) 0))

(define (cand-builder-copy-range!
  [dst : (&mut dst (Array Candidate))]
  [src : (& src (Array Candidate))]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst index (array-ref src index))
        (set! index (+ index 1))))))

(define (cand-builder-grow! [builder : (&mut builder CandBuilder)]) : unit
  (let
    [old-cap : i64 (array-length (struct-get builder slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array Candidate) (make-array Candidate new-cap)]
    (begin
      (cand-builder-copy-range!
        (&mut bigger)
        (& (struct-get builder slots))
        (struct-get builder len))
      (set! (struct-get builder slots) bigger))))

(define (cand-builder-push!
  [builder : (&mut builder CandBuilder)]
  [cand : Candidate]) : unit
  (begin
    (if (< (struct-get builder len) (array-length (struct-get builder slots)))
      unit
      (cand-builder-grow! builder))
    (let
      [index : i64 (struct-get builder len)]
      (begin
        (array-set! (struct-get builder slots) index cand)
        (set! (struct-get builder len) (+ index 1))))))

(define (cand-builder-to-seq [builder : CandBuilder]) : CandSeq
  (CandSeq (struct-get builder slots) (struct-get builder len)))

(defenum ChooserResult
  (Ok Candidate)
  (Err String))

;: Read all of stdin into a single String by repeated bounded reads until EOF.
;: The queue snapshot can exceed 64 KiB once PR check rollups and issue labels
;: accumulate, so use a larger request size for ordinary chooser payloads.
(define stdin-read-size : i64
  1048576)

(define (read-all-stdin-acc [acc : String]) : String
  (let
    [chunk : String (io.read-stdin-bytes stdin-read-size)]
    [text : String (string.append acc chunk)]
    (if (io.stdin-eof?)
      text
      (read-all-stdin-acc text))))

(define (read-all-stdin) : String
  (read-all-stdin-acc ""))

;: PowerShell native pipelines on Windows can prefix stdin with a UTF-8 BOM, and
;: GitHub titles may include UTF-8 punctuation that the current byte-oriented
;: JSON parser cannot decode. The chooser only needs display text, so normalize
;: the queue snapshot to parser-safe ASCII while preserving JSON syntax.
(define (chooser-char-code-at [text : String] [idx : i64]) : i64
  (cast (string.string-ref text idx) : i64))

(define (chooser-has-utf8-bom? [text : String]) : bool
  (and
    (>= (string.string-length text) 3)
    (= (chooser-char-code-at text 0) 239)
    (= (chooser-char-code-at text 1) 187)
    (= (chooser-char-code-at text 2) 191)))

(define (chooser-strip-utf8-bom [text : String]) : String
  (if (chooser-has-utf8-bom? text)
    (string.substring text 3 (- (string.string-length text) 3))
    text))

(define (chooser-normalize-json-input [text : String]) : String
  (let
    [input : String (chooser-strip-utf8-bom text)]
    [n : i64 (string.string-length input)]
    [i : i64 0]
    [segment-start : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (let
          [code : i64 (chooser-char-code-at input i)]
          (if (> code 126)
            (begin
              (set!
                out
                (string.append
                  (string.append
                    out
                    (string.substring input segment-start (- i segment-start)))
                  "?"))
              (set! i (+ i 1))
              (set! segment-start i))
            (set! i (+ i 1)))))
      (string.append
        out
        (string.substring input segment-start (- n segment-start))))))

;: Extract an i64 from a JSON number field, defaulting to 0 when absent/wrong.
(define (json-field-number [item : json.Json] [field : String]) : i64
  (let
    [key : String field]
    (match (json.object-get item (& key))
      [(json.JsonFound found)
        (match found
          [(json.JsonNumber text) (string.>int text)]
          [_ 0])]
      [(json.JsonMissing) 0])))

;: Extract a String from a JSON string field, defaulting to "" when absent.
(define (json-field-string [item : json.Json] [field : String]) : String
  (let
    [key : String field]
    (match (json.object-get item (& key))
      [(json.JsonFound found)
        (match found
          [(json.JsonString text) text]
          [_ ""])]
      [(json.JsonMissing) ""])))

;: Extract a bool from a JSON boolean field, defaulting to false when absent so
;: a PR with no `isDraft` key is treated as a non-draft (open) PR.
(define (json-field-bool [item : json.Json] [field : String]) : bool
  (let
    [key : String field]
    (match (json.object-get item (& key))
      [(json.JsonFound found)
        (match found
          [(json.JsonBool value) value]
          [_ false])]
      [(json.JsonMissing) false])))

;: Look up the JSON array stored at `field`, or an empty sequence when absent.
(define (json-field-array [value : json.Json] [field : String]) : json.JsonSeq
  (let
    [key : String field]
    (match (json.object-get value (& key))
      [(json.JsonFound found)
        (match found
          [(json.JsonArray entries) (box-get entries)]
          [_ (json.list-empty)])]
      [(json.JsonMissing) (json.list-empty)])))

;: True when any object in `labels` has a `name` equal to `needle`.
(define (label-list-has? [labels : json.JsonSeq] [needle : String]) : bool
  (let
    [n : i64 (json.list-count labels)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (begin
          (match (json.list-get-index labels i)
            [(json.JsonFound head)
              (if (string.eq (json-field-string head "name") needle)
                (set! found true)
                unit)]
            [(json.JsonMissing) unit])
          (set! i (+ i 1))))
      found)))

;: Return the `labels` array of an issue, or an empty sequence when absent.
(define (issue-label-list [item : json.Json]) : json.JsonSeq
  (let
    [key : String "labels"]
    (match (json.object-get item (& key))
      [(json.JsonFound found)
        (match found
          [(json.JsonArray entries) (box-get entries)]
          [_ (json.list-empty)])]
      [(json.JsonMissing) (json.list-empty)])))

;: Return the priority bonus for a label list. p0 takes precedence over p1.
(define (label-list-priority-bonus [labels : json.JsonSeq]) : i64
  (if (label-list-has? labels "p0")
    p0-priority-bonus
    (if (label-list-has? labels "p1")
      p1-priority-bonus
      0)))

;: Build a PR candidate (kind = review, no labels considered).
(define (pr-candidate [item : json.Json]) : Candidate
  (Candidate
    kind-pr
    (json-field-number item "number")
    (json-field-string item "title")
    review-weight))

;: Return true when a PR is a draft. Draft PRs are never offered for review.
(define (pr-draft? [item : json.Json]) : bool
  (json-field-bool item "isDraft"))

;: Compare normalized GitHub RFC 3339 timestamps lexicographically. GitHub emits
;: these values in fixed-width UTC form, so byte order is chronological order.
(define (pr-timestamp-after? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string.string-length left)]
    [right-len : i64 (string.string-length right)]
    [common-len : i64
      (if (< left-len right-len)
        left-len
        right-len)]
    [index : i64 0]
    [after : bool false]
    [done : bool false]
    (begin
      (while (and (not done) (< index common-len))
        (let
          [left-code : i64 (chooser-char-code-at left index)]
          [right-code : i64 (chooser-char-code-at right index)]
          (if (> left-code right-code)
            (begin
              (set! after true)
              (set! done true))
            (if (< left-code right-code)
              (set! done true)
              (set! index (+ index 1))))))
      (if done
        after
        (> left-len right-len)))))

;: Return the latest non-empty timestamp at `field` in an object sequence.
(define (pr-latest-seq-timestamp [entries : json.JsonSeq] [field : String]) : String
  (let
    [n : i64 (json.list-count entries)]
    [index : i64 0]
    [latest : String ""]
    (begin
      (while (< index n)
        (begin
          (match (json.list-get-index entries index)
            [(json.JsonFound entry)
              (let
                [candidate : String (json-field-string entry field)]
                (if (pr-timestamp-after? candidate latest)
                  (set! latest candidate)
                  unit))]
            [(json.JsonMissing) unit])
          (set! index (+ index 1))))
      latest)))

;: Return the latest review or issue-comment timestamp supplied for a PR.
(define (pr-latest-review-activity [item : json.Json]) : String
  (let
    [latest-review : String
      (pr-latest-seq-timestamp (json-field-array item "reviews") "submittedAt")]
    [latest-comment : String
      (pr-latest-seq-timestamp (json-field-array item "comments") "createdAt")]
    (if (pr-timestamp-after? latest-comment latest-review)
      latest-comment
      latest-review)))

;: Return true when a review or issue comment settled the current PR head.
;: Missing/wrong-shaped activity or commit fields fail open so legacy producers
;: keep every otherwise eligible PR in the queue during contract rollout.
(define (pr-reviewed-after-latest-commit? [item : json.Json]) : bool
  (let
    [latest-commit : String
      (pr-latest-seq-timestamp
        (json-field-array item "commits")
        "committedDate")]
    [latest-activity : String (pr-latest-review-activity item)]
    (and
      (> (string.string-length latest-commit) 0)
      (> (string.string-length latest-activity) 0)
      (pr-timestamp-after? latest-activity latest-commit))))

;: Return true when a check run status is terminal; conclusions may pass/fail.
(define (pr-check-status-complete? [status : String]) : bool
  (string.eq status "COMPLETED"))

;: Return true when a legacy status context state is terminal.
(define (pr-check-state-complete? [state : String]) : bool
  (or
    (string.eq state "SUCCESS")
    (string.eq state "FAILURE")
    (string.eq state "ERROR")))

;: Return true when a rollup entry is complete. Unknown entries do not block so
;: a missing check shape is treated like no checks rather than a pending check.
(define (pr-check-entry-complete? [entry : json.Json]) : bool
  (let
    [status : String (json-field-string entry "status")]
    (if (> (string.string-length status) 0)
      (pr-check-status-complete? status)
      (let
        [state : String (json-field-string entry "state")]
        (if (> (string.string-length state) 0)
          (pr-check-state-complete? state)
          true)))))

;: Return true when every check rollup entry has reached a terminal state.
(define (pr-check-list-complete? [checks : json.JsonSeq]) : bool
  (let
    [n : i64 (json.list-count checks)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i n))
        (begin
          (match (json.list-get-index checks i)
            [(json.JsonFound head)
              (if (pr-check-entry-complete? head)
                unit
                (set! ok false))]
            [(json.JsonMissing) unit])
          (set! i (+ i 1))))
      ok)))

;: Missing or empty `statusCheckRollup` means the PR has no checks and remains
;: eligible. Only explicitly pending/running entries are skipped.
(define (pr-checks-complete? [item : json.Json]) : bool
  (let
    [key : String "statusCheckRollup"]
    (match (json.object-get item (& key))
      [(json.JsonFound found)
        (match found
          [(json.JsonArray entries) (pr-check-list-complete? (box-get entries))]
          [_ true])]
      [(json.JsonMissing) true])))

;: Build an issue candidate, classifying ready-for-implementation vs triage and
;: adding the priority bonus.
(define (issue-candidate [item : json.Json]) : Candidate
  (let
    [labels : json.JsonSeq (issue-label-list item)]
    [ready : bool (label-list-has? labels "ready-for-implementation")]
    [bonus : i64 (label-list-priority-bonus labels)]
    (if ready
      (Candidate
        kind-ready
        (json-field-number item "number")
        (json-field-string item "title")
        (+ implement-weight bonus))
      (Candidate
        kind-triage
        (json-field-number item "number")
        (json-field-string item "title")
        (+ research-weight bonus)))))

;: Return true when an issue should not enter the active work queue.
(define (issue-blocked? [item : json.Json]) : bool
  (label-list-has? (issue-label-list item) "blocked"))

;: Return true when an issue carries the ready-for-implementation label, i.e. it
;: would classify as an implement candidate.
(define (issue-ready? [item : json.Json]) : bool
  (label-list-has? (issue-label-list item) "ready-for-implementation"))

;: Append a JSON array of PR objects as candidates, preserving source order.
;: Draft PRs are never eligible. Non-draft PRs are skipped while checks are
;: pending/running and after review activity settles their current commit.
(define (pr-candidates-into
  [items : json.JsonSeq]
  [out : (&mut out CandBuilder)]) : unit
  (let
    [n : i64 (json.list-count items)]
    [i : i64 0]
    (while (< i n)
      (begin
        (match (json.list-get-index items i)
          [(json.JsonFound head)
            (if (and
              (not (pr-draft? head))
              (pr-checks-complete? head)
              (not (pr-reviewed-after-latest-commit? head)))
              (cand-builder-push! out (pr-candidate head))
              unit)]
          [(json.JsonMissing) unit])
        (set! i (+ i 1))))))

;: Shortest digit run treated as an issue reference inside a branch name or PR
;: title. Four digits keeps `cycle28-divmod-hoist` and `perf-opt2-cycle1` from
;: claiming issues #28 and #1 while still matching every real reference in this
;: repository, whose issue numbers are four digits and climbing.
(define claim-digit-floor : i64
  4)

;: True when `text` contains `number` as a maximal digit run of at least
;: `claim-digit-floor` digits. Maximal matters: `5641` must not be claimed by a
;: branch mentioning `56412`.
(define (text-claims-number? [text : String] [number : i64]) : bool
  (let
    [needle : String (string.int->string number)]
    [n : i64 (string.string-length text)]
    [m : i64 (string.string-length needle)]
    [i : i64 0]
    [found : bool false]
    (begin
      (if (< m claim-digit-floor)
        unit
        (while (and (not found) (<= (+ i m) n))
          (let
            [before-ok : bool
              (if (= i 0)
                true
                (not (chooser-digit? (string.string-ref text (- i 1)))))]
            [after-ok : bool
              (if (= (+ i m) n)
                true
                (not (chooser-digit? (string.string-ref text (+ i m)))))]
            (begin
              (if (and
                before-ok
                after-ok
                (string.is-string-prefix-at (& text) (& needle) i))
                (set! found true)
                unit)
              (set! i (+ i 1))))))
      found)))

(define (chooser-digit? [c : char]) : bool
  (and (>= c '0') (<= c '9')))

(test
  claim-matches-branch-and-title
  (begin
    (test.assert-true
      (text-claims-number? "implement-5408-folding-ranges" 5408)
      "branch name claims its issue")
    (test.assert-true
      (text-claims-number? "fix-5641-baseline-drift-visibility" 5641)
      "claim may sit between separators")
    (test.assert-true
      (text-claims-number? "tlci-native-template-nodes-5605" 5605)
      "claim may end the string")
    (test.assert-true
      (text-claims-number? "tlci native: computed dispatch (fixes #5604)" 5604)
      "a PR title claims through its Fixes reference")))

(test
  claim-ignores-short-and-partial-numbers
  (begin
    (test.assert-false
      (text-claims-number? "cycle28-divmod-hoist" 28)
      "a 2-digit run is below the claim floor")
    (test.assert-false
      (text-claims-number? "perf-opt2-cycle1" 1)
      "a 1-digit run is below the claim floor")
    (test.assert-false
      (text-claims-number? "branch-56041-thing" 5604)
      "a claim must be a maximal digit run, not a prefix")
    (test.assert-false
      (text-claims-number? "branch-15604-thing" 5604)
      "a claim must be a maximal digit run, not a suffix")
    (test.assert-false
      (text-claims-number? "tlci-str-cat-native" 5617)
      "a branch naming no number claims nothing")))

;: True when some open PR already claims `number` through its branch name or
;: title. An issue someone has opened a PR for is not work to hand to a second
;: agent, so it leaves the pool entirely rather than merely changing lane.
(define (issue-claimed-by-pr? [prs : json.JsonSeq] [number : i64]) : bool
  (let
    [n : i64 (json.list-count prs)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (begin
          (match (json.list-get-index prs i)
            [(json.JsonFound head)
              (if (or
                (text-claims-number?
                  (json-field-string head "headRefName")
                  number)
                (text-claims-number? (json-field-string head "title") number))
                (set! found true)
                unit)]
            [(json.JsonMissing) unit])
          (set! i (+ i 1))))
      found)))

;: Append a JSON array of issue objects as candidates, preserving source order.
;: Blocked issues are always skipped, as are issues an open PR already claims;
;: ready-for-implementation issues are also skipped when `implement-allowed?` is
;: false (the review queue is saturated).
(define (issue-candidates-into
  [items : json.JsonSeq]
  [prs : json.JsonSeq]
  [implement-allowed? : bool]
  [out : (&mut out CandBuilder)]) : unit
  (let
    [n : i64 (json.list-count items)]
    [i : i64 0]
    (while (< i n)
      (begin
        (match (json.list-get-index items i)
          [(json.JsonFound head)
            (if (or
              (issue-blocked? head)
              (issue-claimed-by-pr? prs (json-field-number head "number"))
              (and (not implement-allowed?) (issue-ready? head)))
              unit
              (cand-builder-push! out (issue-candidate head)))]
          [(json.JsonMissing) unit])
        (set! i (+ i 1))))))

;: Count open non-draft PRs in the raw `prs` array. Draft PRs and a missing
;: `isDraft` field are handled by `json-field-bool` (missing => non-draft).
(define (count-open-nondraft-prs [items : json.JsonSeq]) : i64
  (let
    [n : i64 (json.list-count items)]
    [i : i64 0]
    [open : i64 0]
    (begin
      (while (< i n)
        (begin
          (match (json.list-get-index items i)
            [(json.JsonFound head)
              (if (json-field-bool head "isDraft")
                unit
                (set! open (+ open 1)))]
            [(json.JsonMissing) unit])
          (set! i (+ i 1))))
      open)))

;: Build the full candidate sequence: PR candidates first, then issue
;: candidates. Ready-for-implementation issues are dropped once more than
;: `implement-pr-cap` open non-draft PRs are present, leaving only review and
;: research/triage work.
(define (build-candidates [root : json.Json]) : CandSeq
  (let
    [prs : json.JsonSeq (json-field-array root "prs")]
    [issues : json.JsonSeq (json-field-array root "issues")]
    [implement-allowed? : bool
      (<= (count-open-nondraft-prs prs) implement-pr-cap)]
    [out : CandBuilder (cand-builder-new)]
    (begin
      (pr-candidates-into prs (&mut out))
      (issue-candidates-into issues prs implement-allowed? (&mut out))
      (cand-builder-to-seq out))))

;: Number of candidates in a sequence.
(define (cand-count [cands : CandSeq]) : i64
  (struct-get cands len))

;: Return the candidate at zero-based `index`, or a sentinel triage candidate
;: when out of range (should not happen for a valid weighted index).
(define (cand-nth [cands : CandSeq] [index : i64]) : Candidate
  (if (or (< index 0) (>= index (struct-get cands len)))
    (Candidate kind-triage 0 "" research-weight)
    (array-ref (struct-get cands slots) index)))

;: Build the weight list from candidates, preserving order so a chosen weight
;: index maps back to the candidate at the same position.
(define (cand-weights-from [cands : CandSeq] [index : i64]) : random.RandomWeightList
  (if (>= index (cand-count cands))
    (random.weight-list-empty)
    (random.weight-list-cons
      (struct-get (cand-nth cands index) weight)
      (cand-weights-from cands (+ index 1)))))

(define (cand-weights [cands : CandSeq]) : random.RandomWeightList
  (cand-weights-from cands 0))

;: True when any candidate in the sequence has the given kind tag.
(define (cand-list-has-kind? [cands : CandSeq] [target-kind : i64]) : bool
  (let
    [n : i64 (cand-count cands)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (begin
          (if (= (struct-get (cand-nth cands i) kind) target-kind)
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

(test
  chooser-skips-incomplete-pr-checks
  (let
    [text : String
      "{\"prs\":[{\"number\":1,\"title\":\"No checks\",\"isDraft\":false},{\"number\":2,\"title\":\"Empty checks\",\"statusCheckRollup\":[]},{\"number\":3,\"title\":\"Completed checks\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"COMPLETED\",\"conclusion\":\"FAILURE\"}]},{\"number\":4,\"title\":\"Running checks\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"IN_PROGRESS\"}]},{\"number\":5,\"title\":\"Pending status\",\"statusCheckRollup\":[{\"__typename\":\"StatusContext\",\"state\":\"PENDING\"}]},{\"number\":6,\"title\":\"Failed status\",\"statusCheckRollup\":[{\"__typename\":\"StatusContext\",\"state\":\"FAILURE\"}]}],\"issues\":[{\"number\":7,\"title\":\"Fallback issue\",\"labels\":[]}]}"]
    (match (json.parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandSeq (build-candidates root)]
          (begin
            (if (= (cand-count cands) 5)
              unit
              (io.panic "expected only complete/no-check PRs plus issue"))
            (if (= (struct-get (cand-nth cands 0) number) 1)
              unit
              (io.panic "non-draft PR without checks should remain eligible"))
            (if (= (struct-get (cand-nth cands 1) number) 2)
              unit
              (io.panic "empty check rollup should remain eligible"))
            (if (= (struct-get (cand-nth cands 2) number) 3)
              unit
              (io.panic "completed check run should remain eligible"))
            (if (= (struct-get (cand-nth cands 3) number) 6)
              unit
              (io.panic "terminal legacy status should remain eligible"))
            (if (= (struct-get (cand-nth cands 4) number) 7)
              unit
              (io.panic "issue should remain after skipped PRs"))))]
      [(json.ErrJson _) (io.panic "test JSON should parse")])))

(test
  chooser-skips-reviewed-pr-until-a-new-push
  (let
    [text : String
      "{\"prs\":[{\"number\":100,\"title\":\"Comment settled\",\"isDraft\":false,\"statusCheckRollup\":[],\"commits\":[{\"committedDate\":\"2026-07-26T10:00:00Z\"}],\"reviews\":[],\"comments\":[{\"createdAt\":\"2026-07-26T10:01:00Z\"}]},{\"number\":101,\"title\":\"Pushed again\",\"isDraft\":false,\"statusCheckRollup\":[],\"commits\":[{\"committedDate\":\"2026-07-26T10:00:00Z\"},{\"committedDate\":\"2026-07-26T10:02:00Z\"}],\"reviews\":[{\"submittedAt\":\"2026-07-26T10:00:30Z\"}],\"comments\":[{\"createdAt\":\"2026-07-26T10:01:00Z\"}]},{\"number\":102,\"title\":\"Never reviewed\",\"isDraft\":false,\"statusCheckRollup\":[],\"commits\":[{\"committedDate\":\"2026-07-26T10:00:00Z\"}],\"reviews\":[],\"comments\":[]},{\"number\":103,\"title\":\"Legacy payload\",\"isDraft\":false,\"statusCheckRollup\":[]},{\"number\":104,\"title\":\"Review settled\",\"isDraft\":false,\"statusCheckRollup\":[],\"commits\":[{\"committedDate\":\"2026-07-26T10:00:00Z\"}],\"reviews\":[{\"submittedAt\":\"2026-07-26T10:03:00Z\"}],\"comments\":[{\"createdAt\":\"2026-07-26T09:59:00Z\"}]}],\"issues\":[]}"]
    (match (json.parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandSeq (build-candidates root)]
          (begin
            (if (= (cand-count cands) 3)
              unit
              (io.panic
                "expected pushed, never-reviewed, and legacy PR candidates"))
            (if (= (struct-get (cand-nth cands 0) number) 101)
              unit
              (io.panic "a push after review must make the PR eligible again"))
            (if (= (struct-get (cand-nth cands 1) number) 102)
              unit
              (io.panic "a PR with no review activity must remain eligible"))
            (if (= (struct-get (cand-nth cands 2) number) 103)
              unit
              (io.panic "missing activity data must fail open"))))]
      [(json.ErrJson _) (io.panic "test JSON should parse")])))

(test
  chooser-p0-label-takes-precedence-over-p1
  (let
    [text : String
      "{\"prs\":[],\"issues\":[{\"number\":10,\"title\":\"Both priorities\",\"labels\":[{\"name\":\"ready-for-implementation\"},{\"name\":\"p1\"},{\"name\":\"p0\"}]},{\"number\":11,\"title\":\"P1 only\",\"labels\":[{\"name\":\"ready-for-implementation\"},{\"name\":\"p1\"}]}]}"]
    (match (json.parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandSeq (build-candidates root)]
          (begin
            (if (= (cand-count cands) 2)
              unit
              (io.panic "expected two issue candidates"))
            (if (=
              (struct-get (cand-nth cands 0) weight)
              (+ implement-weight p0-priority-bonus))
              unit
              (io.panic "issue with p0 and p1 should use p0 priority"))
            (if (=
              (struct-get (cand-nth cands 1) weight)
              (+ implement-weight p1-priority-bonus))
              unit
              (io.panic "issue with only p1 should use p1 priority"))))]
      [(json.ErrJson _) (io.panic "test JSON should parse")])))

(test
  chooser-skips-blocked-issues
  (let
    [text : String
      "{\"prs\":[],\"issues\":[{\"number\":30,\"title\":\"Blocked triage\",\"labels\":[{\"name\":\"blocked\"}]},{\"number\":31,\"title\":\"Blocked ready\",\"labels\":[{\"name\":\"blocked\"},{\"name\":\"ready-for-implementation\"}]},{\"number\":32,\"title\":\"Ready issue\",\"labels\":[{\"name\":\"ready-for-implementation\"}]},{\"number\":33,\"title\":\"Triage issue\",\"labels\":[]}]}"]
    (match (json.parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandSeq (build-candidates root)]
          (begin
            (if (= (cand-count cands) 2)
              unit
              (io.panic "expected blocked issues to be skipped"))
            (if (= (struct-get (cand-nth cands 0) number) 32)
              unit
              (io.panic "first non-blocked issue should remain eligible"))
            (if (= (struct-get (cand-nth cands 1) number) 33)
              unit
              (io.panic "second non-blocked issue should remain eligible"))))]
      [(json.ErrJson _) (io.panic "test JSON should parse")])))

(test
  chooser-pr-review-weight-is-raised
  (let
    [text : String
      "{\"prs\":[{\"number\":20,\"title\":\"Review me\",\"statusCheckRollup\":[]}],\"issues\":[]}"]
    (match (json.parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandSeq (build-candidates root)]
          (begin
            (if (= (cand-count cands) 1)
              unit
              (io.panic "expected one PR candidate"))
            (if (= (struct-get (cand-nth cands 0) weight) 45)
              unit
              (io.panic "PR review weight should be 45"))))]
      [(json.ErrJson _) (io.panic "test JSON should parse")])))

(test
  chooser-never-chooses-draft-prs
  (let
    [text : String
      "{\"prs\":[{\"number\":60,\"title\":\"Draft passing\",\"isDraft\":true,\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]},{\"number\":61,\"title\":\"Draft no checks\",\"isDraft\":true},{\"number\":62,\"title\":\"Open passing\",\"isDraft\":false,\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]}],\"issues\":[{\"number\":70,\"title\":\"Triage issue\",\"labels\":[]}]}"]
    (match (json.parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandSeq (build-candidates root)]
          (begin
            (if (= (cand-count cands) 2)
              unit
              (io.panic
                "only the non-draft PR and the triage issue should remain"))
            (if (= (struct-get (cand-nth cands 0) number) 62)
              unit
              (io.panic
                "the sole non-draft PR should be the only review candidate"))
            (if (= (struct-get (cand-nth cands 1) number) 70)
              unit
              (io.panic "triage issue should follow once draft PRs are dropped"))))]
      [(json.ErrJson _) (io.panic "test JSON should parse")])))

(test
  chooser-caps-implement-when-many-open-prs
  (let
    [text : String
      "{\"prs\":[{\"number\":40,\"title\":\"PR A\",\"isDraft\":false,\"statusCheckRollup\":[]},{\"number\":41,\"title\":\"PR B\",\"isDraft\":false,\"statusCheckRollup\":[]},{\"number\":42,\"title\":\"PR C\",\"isDraft\":false,\"statusCheckRollup\":[]},{\"number\":43,\"title\":\"PR D\",\"isDraft\":false,\"statusCheckRollup\":[]}],\"issues\":[{\"number\":50,\"title\":\"Ready issue\",\"labels\":[{\"name\":\"ready-for-implementation\"}]},{\"number\":51,\"title\":\"Triage issue\",\"labels\":[]}]}"]
    (match (json.parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandSeq (build-candidates root)]
          (begin
            (if (= (cand-count cands) 5)
              unit
              (io.panic
                "four review PRs plus the surviving triage issue expected"))
            (if (cand-list-has-kind? cands kind-ready)
              (io.panic
                "ready-for-implementation issues must drop above the PR cap")
              unit)
            (if (cand-list-has-kind? cands kind-pr)
              unit
              (io.panic "review candidates must stay eligible above the PR cap"))
            (if (cand-list-has-kind? cands kind-triage)
              unit
              (io.panic
                "research/triage issues must stay eligible above the PR cap"))
            (if (= (struct-get (cand-nth cands 4) number) 51)
              unit
              (io.panic "triage issue should remain after the four review PRs"))))]
      [(json.ErrJson _) (io.panic "test JSON should parse")])))

(test
  chooser-allows-implement-at-pr-cap-boundary
  (let
    [text : String
      "{\"prs\":[{\"number\":40,\"title\":\"PR A\",\"isDraft\":false,\"statusCheckRollup\":[]},{\"number\":41,\"title\":\"PR B\",\"isDraft\":false,\"statusCheckRollup\":[]},{\"number\":42,\"title\":\"PR C\",\"isDraft\":false,\"statusCheckRollup\":[]}],\"issues\":[{\"number\":50,\"title\":\"Ready issue\",\"labels\":[{\"name\":\"ready-for-implementation\"}]},{\"number\":51,\"title\":\"Triage issue\",\"labels\":[]}]}"]
    (match (json.parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandSeq (build-candidates root)]
          (begin
            (if (= (cand-count cands) 5)
              unit
              (io.panic "three review PRs plus both issues expected at the cap"))
            (if (cand-list-has-kind? cands kind-ready)
              unit
              (io.panic "exactly three open PRs is at the cap, not above it"))
            (if (= (struct-get (cand-nth cands 3) number) 50)
              unit
              (io.panic "ready issue should remain right at the PR cap"))))]
      [(json.ErrJson _) (io.panic "test JSON should parse")])))

(test
  chooser-draft-prs-do-not-count-toward-pr-cap
  (let
    [text : String
      "{\"prs\":[{\"number\":40,\"title\":\"PR A\",\"isDraft\":false,\"statusCheckRollup\":[]},{\"number\":41,\"title\":\"PR B\",\"isDraft\":false,\"statusCheckRollup\":[]},{\"number\":42,\"title\":\"PR C\",\"isDraft\":false,\"statusCheckRollup\":[]},{\"number\":43,\"title\":\"Draft D\",\"isDraft\":true,\"statusCheckRollup\":[]},{\"number\":44,\"title\":\"Draft E\",\"isDraft\":true,\"statusCheckRollup\":[]}],\"issues\":[{\"number\":50,\"title\":\"Ready issue\",\"labels\":[{\"name\":\"ready-for-implementation\"}]}]}"]
    (match (json.parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandSeq (build-candidates root)]
          (begin
            (if (= (cand-count cands) 4)
              unit
              (io.panic
                "three non-draft review PRs plus the kept ready issue expected"))
            (if (cand-list-has-kind? cands kind-ready)
              unit
              (io.panic
                "two draft PRs must not push three open PRs over the cap"))
            (if (= (struct-get (cand-nth cands 3) number) 50)
              unit
              (io.panic "ready issue should sit right after the non-draft PRs"))))]
      [(json.ErrJson _) (io.panic "test JSON should parse")])))

(test
  chooser-implement-cap-can-empty-queue-when-only-ready-issues
  (let
    [text : String
      "{\"prs\":[{\"number\":40,\"title\":\"PR A\",\"isDraft\":false,\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"IN_PROGRESS\"}]},{\"number\":41,\"title\":\"PR B\",\"isDraft\":false,\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"IN_PROGRESS\"}]},{\"number\":42,\"title\":\"PR C\",\"isDraft\":false,\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"IN_PROGRESS\"}]},{\"number\":43,\"title\":\"PR D\",\"isDraft\":false,\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"IN_PROGRESS\"}]}],\"issues\":[{\"number\":50,\"title\":\"Ready issue\",\"labels\":[{\"name\":\"ready-for-implementation\"}]},{\"number\":51,\"title\":\"Another ready\",\"labels\":[{\"name\":\"ready-for-implementation\"},{\"name\":\"p1\"}]}]}"]
    (match (json.parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandSeq (build-candidates root)]
          (if (= (cand-count cands) 0)
            unit
            (io.panic
              "saturated PRs with only ready issues should leave no work")))]
      [(json.ErrJson _) (io.panic "test JSON should parse")])))

;: The action verb for a candidate kind.
(define (action-name [kind : i64]) : String
  (if (= kind kind-pr)
    "review"
    (if (= kind kind-ready)
      "implement"
      "research/triage")))

;: The GitHub object word for a candidate kind.
(define (github-kind [kind : i64]) : String
  (if (= kind kind-pr)
    "pr"
    "issue"))

;: Render one candidate as the chooser's action line (without trailing newline).
(define (candidate-line [cand : Candidate]) : String
  (string.append
    (string.append (action-name (struct-get cand kind)) " ")
    (string.append
      (string.append (github-kind (struct-get cand kind)) " #")
      (string.append
        (string.int->string (struct-get cand number))
        (string.append ": " (struct-get cand title))))))

;: Choose one candidate from the input JSON, returning an error message on
;: invalid input or an empty candidate set.
(define (choose-candidate [text : String]) : ChooserResult
  (let
    [normalized : String (chooser-normalize-json-input text)]
    [text : String normalized]
    (match (json.parse (& text))
      [(json.ErrJson message)
        (ChooserResult.Err (string.append "Error: invalid JSON: " message))]
      [(json.OkJson root)
        (let
          [cands : CandSeq (build-candidates root)]
          (if (= (cand-count cands) 0)
            (ChooserResult.Err "Error: no eligible candidates were provided")
            (match (random.system-seed)
              [(random.ErrSystemSeed err)
                (ChooserResult.Err
                  (match err
                    [(random.RandomSystemSeedUnavailable message)
                      (string.append "Error: " message)]))]
              [(random.OkSystemSeed seed)
                (match (random.weighted-index
                  (random.seed seed)
                  (cand-weights cands))
                  [(random.ErrRandomWeightedIndex message)
                    (ChooserResult.Err (string.append "Error: " message))]
                  [(random.OkRandomWeightedIndex _ index)
                    (ChooserResult.Ok (cand-nth cands index))])])))])))

(define (main) : i64
  (match (choose-candidate (read-all-stdin))
    [(ChooserResult.Err message)
      (begin
        (io.print-error message)
        1)]
    [(ChooserResult.Ok cand)
      (begin
        (io.print-string (candidate-line cand))
        (io.print-newline)
        0)]))