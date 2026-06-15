;# work-queue-chooser/chooser.tl - TypeLisp work-queue chooser (#794).
;#
;# Reads the combined `{"prs":[...],"issues":[...]}` JSON from stdin, classifies
;# each entry, skips draft PRs and PRs whose checks are still pending/running as
;# well as issues labeled `blocked`, weights the rest (PR review = 45,
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

;: Immutable list of candidates in source order (PRs first, then issues).
(defenum CandList
  (CandNil)
  (CandCons Candidate (Box CandList)))

(defenum ChooserResult
  (ChooserOk Candidate)
  (ChooserErr String))

;: Read all of stdin into a single String by repeated bounded reads until EOF.
;: The queue snapshot can exceed 64 KiB once PR check rollups and issue labels
;: accumulate, so use a larger request size for ordinary chooser payloads.
(define stdin-read-size : i64
  1048576)

(define (read-all-stdin-acc [acc : String]) : String
  (let
    [chunk : String (io.read-stdin-bytes stdin-read-size)]
    [text : String (string.string-append acc chunk)]
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
  (cast (string-ref text idx) : i64))

(define (chooser-has-utf8-bom? [text : String]) : bool
  (and
    (>= (string-length text) 3)
    (= (chooser-char-code-at text 0) 239)
    (= (chooser-char-code-at text 1) 187)
    (= (chooser-char-code-at text 2) 191)))

(define (chooser-strip-utf8-bom [text : String]) : String
  (if (chooser-has-utf8-bom? text)
    (string.substring text 3 (- (string-length text) 3))
    text))

(define (chooser-normalize-json-input [text : String]) : String
  (let
    [input : String (chooser-strip-utf8-bom text)]
    [n : i64 (string-length input)]
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
                (string.string-append
                  (string.string-append
                    out
                    (string.substring input segment-start (- i segment-start)))
                  "?"))
              (set! i (+ i 1))
              (set! segment-start i))
            (set! i (+ i 1)))))
      (string.string-append
        out
        (string.substring input segment-start (- n segment-start))))))

;: Extract an i64 from a JSON number field, defaulting to 0 when absent/wrong.
(define (json-field-number [item : json.Json] [field : String]) : i64
  (let
    [key : String field]
    (match (json.json-object-get item (& key))
      [(json.JsonFound found)
        (match found
          [(json.JsonNumber text) (string.string->int text)]
          [_ 0])]
      [(json.JsonMissing) 0])))

;: Extract a String from a JSON string field, defaulting to "" when absent.
(define (json-field-string [item : json.Json] [field : String]) : String
  (let
    [key : String field]
    (match (json.json-object-get item (& key))
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
    (match (json.json-object-get item (& key))
      [(json.JsonFound found)
        (match found
          [(json.JsonBool value) value]
          [_ false])]
      [(json.JsonMissing) false])))

;: True when any object in `labels` has a `name` equal to `needle`.
(define (label-list-has? [labels : json.JsonList] [needle : String]) : bool
  (match labels
    [(json.JsonListNil) false]
    [(json.JsonListCons head rest)
      (if (string.string-eq (json-field-string head "name") needle)
        true
        (label-list-has? (box-get rest) needle))]))

;: Return the `labels` array of an issue, or an empty list when absent.
(define (issue-label-list [item : json.Json]) : json.JsonList
  (let
    [key : String "labels"]
    (match (json.json-object-get item (& key))
      [(json.JsonFound found)
        (match found
          [(json.JsonArray entries) (box-get entries)]
          [_ (json.JsonListNil)])]
      [(json.JsonMissing) (json.JsonListNil)])))

;: Return the priority bonus for a label list. p0 takes precedence over p1.
(define (label-list-priority-bonus [labels : json.JsonList]) : i64
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

;: Return true when a check run status is terminal; conclusions may pass/fail.
(define (pr-check-status-complete? [status : String]) : bool
  (string.string-eq status "COMPLETED"))

;: Return true when a legacy status context state is terminal.
(define (pr-check-state-complete? [state : String]) : bool
  (or
    (string.string-eq state "SUCCESS")
    (string.string-eq state "FAILURE")
    (string.string-eq state "ERROR")))

;: Return true when a rollup entry is complete. Unknown entries do not block so
;: a missing check shape is treated like no checks rather than a pending check.
(define (pr-check-entry-complete? [entry : json.Json]) : bool
  (let
    [status : String (json-field-string entry "status")]
    (if (> (string-length status) 0)
      (pr-check-status-complete? status)
      (let
        [state : String (json-field-string entry "state")]
        (if (> (string-length state) 0)
          (pr-check-state-complete? state)
          true)))))

;: Return true when every check rollup entry has reached a terminal state.
(define (pr-check-list-complete? [checks : json.JsonList]) : bool
  (match checks
    [(json.JsonListNil) true]
    [(json.JsonListCons head rest)
      (if (pr-check-entry-complete? head)
        (pr-check-list-complete? (box-get rest))
        false)]))

;: Missing or empty `statusCheckRollup` means the PR has no checks and remains
;: eligible. Only explicitly pending/running entries are skipped.
(define (pr-checks-complete? [item : json.Json]) : bool
  (let
    [key : String "statusCheckRollup"]
    (match (json.json-object-get item (& key))
      [(json.JsonFound found)
        (match found
          [(json.JsonArray entries) (pr-check-list-complete? (box-get entries))]
          [_ true])]
      [(json.JsonMissing) true])))

;: Build an issue candidate, classifying ready-for-implementation vs triage and
;: adding the priority bonus.
(define (issue-candidate [item : json.Json]) : Candidate
  (let
    [labels : json.JsonList (issue-label-list item)]
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

;: Map a JSON array of PR objects to candidates, preserving source order. Draft
;: PRs are never eligible, and non-draft PRs whose checks are still pending or
;: running are skipped until their checks reach a terminal state.
(define (pr-candidates [items : json.JsonList]) : CandList
  (match items
    [(json.JsonListNil) (CandNil)]
    [(json.JsonListCons head rest)
      (let
        [tail : CandList (pr-candidates (box-get rest))]
        (if (and (not (pr-draft? head)) (pr-checks-complete? head))
          (CandCons (pr-candidate head) (box tail))
          tail))]))

;: Map a JSON array of issue objects to candidates, preserving source order.
;: Blocked issues are always skipped; ready-for-implementation issues are also
;: skipped when `implement-allowed?` is false (the review queue is saturated).
(define (issue-candidates [items : json.JsonList] [implement-allowed? : bool]) : CandList
  (match items
    [(json.JsonListNil) (CandNil)]
    [(json.JsonListCons head rest)
      (let
        [tail : CandList (issue-candidates (box-get rest) implement-allowed?)]
        (if (or
          (issue-blocked? head)
          (and (not implement-allowed?) (issue-ready? head)))
          tail
          (CandCons (issue-candidate head) (box tail))))]))

;: Concatenate two candidate lists, preserving order.
(define (cand-append [front : CandList] [back : CandList]) : CandList
  (match front
    [(CandNil) back]
    [(CandCons head rest)
      (CandCons head (box (cand-append (box-get rest) back)))]))

;: Look up the JSON array stored at `field`, or an empty list when absent.
(define (json-field-array [value : json.Json] [field : String]) : json.JsonList
  (let
    [key : String field]
    (match (json.json-object-get value (& key))
      [(json.JsonFound found)
        (match found
          [(json.JsonArray entries) (box-get entries)]
          [_ (json.JsonListNil)])]
      [(json.JsonMissing) (json.JsonListNil)])))

;: Count open non-draft PRs in the raw `prs` array. Draft PRs and a missing
;: `isDraft` field are handled by `json-field-bool` (missing => non-draft).
(define (count-open-nondraft-prs [items : json.JsonList]) : i64
  (match items
    [(json.JsonListNil) 0]
    [(json.JsonListCons head rest)
      (let
        [tail : i64 (count-open-nondraft-prs (box-get rest))]
        (if (json-field-bool head "isDraft")
          tail
          (+ 1 tail)))]))

;: Build the full candidate list: PR candidates first, then issue candidates.
;: Ready-for-implementation issues are dropped once more than `implement-pr-cap`
;: open non-draft PRs are present, leaving only review and research/triage work.
(define (build-candidates [root : json.Json]) : CandList
  (let
    [prs : json.JsonList (json-field-array root "prs")]
    [issues : json.JsonList (json-field-array root "issues")]
    [implement-allowed? : bool
      (<= (count-open-nondraft-prs prs) implement-pr-cap)]
    (cand-append
      (pr-candidates prs)
      (issue-candidates issues implement-allowed?))))

;: Build the weight list from candidates, preserving order so a chosen weight
;: index maps back to the candidate at the same position.
(define (cand-weights [cands : CandList]) : random.RandomWeightList
  (match cands
    [(CandNil) (random.random-weight-list-empty)]
    [(CandCons head rest)
      (random.random-weight-list-cons
        (struct-get head weight)
        (cand-weights (box-get rest)))]))

;: Return the candidate at zero-based `index`, or a sentinel triage candidate
;: when out of range (should not happen for a valid weighted index).
(define (cand-nth [cands : CandList] [index : i64]) : Candidate
  (match cands
    [(CandNil) (Candidate kind-triage 0 "" research-weight)]
    [(CandCons head rest)
      (if (= index 0)
        head
        (cand-nth (box-get rest) (- index 1)))]))

;: Number of candidates in a list.
(define (cand-count [cands : CandList]) : i64
  (match cands
    [(CandNil) 0]
    [(CandCons _ rest) (+ 1 (cand-count (box-get rest)))]))

;: True when any candidate in the list has the given kind tag.
(define (cand-list-has-kind? [cands : CandList] [target-kind : i64]) : bool
  (match cands
    [(CandNil) false]
    [(CandCons head rest)
      (if (= (struct-get head kind) target-kind)
        true
        (cand-list-has-kind? (box-get rest) target-kind))]))

(test
  chooser-skips-incomplete-pr-checks
  (let
    [text : String
      "{\"prs\":[{\"number\":1,\"title\":\"No checks\",\"isDraft\":false},{\"number\":2,\"title\":\"Empty checks\",\"statusCheckRollup\":[]},{\"number\":3,\"title\":\"Completed checks\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"COMPLETED\",\"conclusion\":\"FAILURE\"}]},{\"number\":4,\"title\":\"Running checks\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"IN_PROGRESS\"}]},{\"number\":5,\"title\":\"Pending status\",\"statusCheckRollup\":[{\"__typename\":\"StatusContext\",\"state\":\"PENDING\"}]},{\"number\":6,\"title\":\"Failed status\",\"statusCheckRollup\":[{\"__typename\":\"StatusContext\",\"state\":\"FAILURE\"}]}],\"issues\":[{\"number\":7,\"title\":\"Fallback issue\",\"labels\":[]}]}"]
    (match (json.json-parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandList (build-candidates root)]
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
  chooser-p0-label-takes-precedence-over-p1
  (let
    [text : String
      "{\"prs\":[],\"issues\":[{\"number\":10,\"title\":\"Both priorities\",\"labels\":[{\"name\":\"ready-for-implementation\"},{\"name\":\"p1\"},{\"name\":\"p0\"}]},{\"number\":11,\"title\":\"P1 only\",\"labels\":[{\"name\":\"ready-for-implementation\"},{\"name\":\"p1\"}]}]}"]
    (match (json.json-parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandList (build-candidates root)]
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
    (match (json.json-parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandList (build-candidates root)]
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
    (match (json.json-parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandList (build-candidates root)]
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
    (match (json.json-parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandList (build-candidates root)]
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
    (match (json.json-parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandList (build-candidates root)]
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
    (match (json.json-parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandList (build-candidates root)]
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
    (match (json.json-parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandList (build-candidates root)]
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
    (match (json.json-parse (& text))
      [(json.OkJson root)
        (let
          [cands : CandList (build-candidates root)]
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
  (string.string-append
    (string.string-append (action-name (struct-get cand kind)) " ")
    (string.string-append
      (string.string-append (github-kind (struct-get cand kind)) " #")
      (string.string-append
        (string.int->string (struct-get cand number))
        (string.string-append ": " (struct-get cand title))))))

;: Choose one candidate from the input JSON, returning an error message on
;: invalid input or an empty candidate set.
(define (choose-candidate [text : String]) : ChooserResult
  (let
    [normalized : String (chooser-normalize-json-input text)]
    [text : String normalized]
    (match (json.json-parse (& text))
      [(json.ErrJson message)
        (ChooserErr (string.string-append "Error: invalid JSON: " message))]
      [(json.OkJson root)
        (let
          [cands : CandList (build-candidates root)]
          (if (= (cand-count cands) 0)
            (ChooserErr "Error: no eligible candidates were provided")
            (match (random.random-system-seed)
              [(random.ErrSystemSeed err)
                (ChooserErr
                  (match err
                    [(random.RandomSystemSeedUnavailable message)
                      (string.string-append "Error: " message)]))]
              [(random.OkSystemSeed seed)
                (match (random.random-weighted-index
                  (random.random-seed seed)
                  (cand-weights cands))
                  [(random.ErrRandomWeightedIndex message)
                    (ChooserErr (string.string-append "Error: " message))]
                  [(random.OkRandomWeightedIndex _ index)
                    (ChooserOk (cand-nth cands index))])])))])))

(define (main) : i64
  (match (choose-candidate (read-all-stdin))
    [(ChooserErr message)
      (begin
        (io.print-error message)
        1)]
    [(ChooserOk cand)
      (begin
        (io.print-string (candidate-line cand))
        (io.print-newline)
        0)]))