;;;; work-queue-chooser/chooser.tl - TypeLisp port of the Rust work-queue chooser (#794).
;;;;
;;;; Reads the combined `{"prs":[...],"issues":[...]}` JSON from stdin, classifies
;;;; each entry, skips PRs whose checks are still pending/running, weights the
;;;; rest (PR review = 30, ready-for-implementation = 10, research/triage = 1,
;;;; +50 for a p0 label, +3 for a p1 label), makes a system-seeded weighted
;;;; pick, and prints one action line:
;;;;
;;;;   review pr #N: Title
;;;;   implement issue #N: Title
;;;;   research/triage issue #N: Title
;;;;
;;;; Selection uses host entropy through `stdlib/random.tl`; JSON parsing uses
;;;; `stdlib/json.tl`.
;;;;
;;;; Usage: `typelisp run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib`
(import "stdlib/json.tl")

(import "stdlib/random.tl")

;;; Kind tags: 0 = PR (review), 1 = ready-for-implementation issue (implement),
;;; 2 = research/triage issue.
(define kind-pr : i64
  0)

(define kind-ready : i64
  1)

(define kind-triage : i64
  2)

(define review-weight : i64
  30)

(define implement-weight : i64
  10)

(define research-weight : i64
  1)

(define p0-priority-bonus : i64
  50)

(define p1-priority-bonus : i64
  3)

;;; A classified work-queue candidate carrying its display fields and weight.
(defstruct Candidate
  (kind i64)
  (number i64)
  (title String)
  (weight i64))

;;; Immutable list of candidates in source order (PRs first, then issues).
(defenum CandList
  (CandNil)
  (CandCons Candidate CandList))

(defenum ChooserResult
  (ChooserOk Candidate)
  (ChooserErr String))

;;; Read all of stdin into a single String by repeated bounded reads until EOF.
(define (read-all-stdin-acc [acc : String]) : String
  (let
    [chunk : String (read-stdin-bytes 65536)]
    (let
      [text : String (string-append acc chunk)]
      (if (stdin-eof?)
        text
        (read-all-stdin-acc text)))))

(define (read-all-stdin) : String
  (read-all-stdin-acc ""))

;;; Extract an i64 from a JSON number field, defaulting to 0 when absent/wrong.
(define (json-field-number [item : Json] [field : String]) : i64
  (match (json-object-get item field)
    [(JsonFound found)
      (match found
        [(JsonNumber text) (string->int text)]
        [_ 0])]
    [(JsonMissing) 0]))

;;; Extract a String from a JSON string field, defaulting to "" when absent.
(define (json-field-string [item : Json] [field : String]) : String
  (match (json-object-get item field)
    [(JsonFound found)
      (match found
        [(JsonString text) text]
        [_ ""])]
    [(JsonMissing) ""]))

;;; True when any object in `labels` has a `name` equal to `needle`.
(define (label-list-has? [labels : JsonList] [needle : String]) : bool
  (match labels
    [(JsonListNil) false]
    [(JsonListCons head rest)
      (if (string-eq (json-field-string head "name") needle)
        true
        (label-list-has? rest needle))]))

;;; Return the `labels` array of an issue, or an empty list when absent.
(define (issue-label-list [item : Json]) : JsonList
  (match (json-object-get item "labels")
    [(JsonFound found)
      (match found
        [(JsonArray entries) entries]
        [_ (JsonListNil)])]
    [(JsonMissing) (JsonListNil)]))

;;; Return the priority bonus for a label list. p0 takes precedence over p1.
(define (label-list-priority-bonus [labels : JsonList]) : i64
  (if (label-list-has? labels "p0")
    p0-priority-bonus
    (if (label-list-has? labels "p1")
      p1-priority-bonus
      0)))

;;; Build a PR candidate (kind = review, no labels considered).
(define (pr-candidate [item : Json]) : Candidate
  (Candidate
    kind-pr
    (json-field-number item "number")
    (json-field-string item "title")
    review-weight))

;;; Return true when a check run status is terminal; conclusions may pass/fail.
(define (pr-check-status-complete? [status : String]) : bool
  (string-eq status "COMPLETED"))

;;; Return true when a legacy status context state is terminal.
(define (pr-check-state-complete? [state : String]) : bool
  (or
    (string-eq state "SUCCESS")
    (or (string-eq state "FAILURE") (string-eq state "ERROR"))))

;;; Return true when a rollup entry is complete. Unknown entries do not block so
;;; a missing check shape is treated like no checks rather than a pending check.
(define (pr-check-entry-complete? [entry : Json]) : bool
  (let
    [status : String (json-field-string entry "status")]
    (if (> (string-length status) 0)
      (pr-check-status-complete? status)
      (let
        [state : String (json-field-string entry "state")]
        (if (> (string-length state) 0)
          (pr-check-state-complete? state)
          true)))))

;;; Return true when every check rollup entry has reached a terminal state.
(define (pr-check-list-complete? [checks : JsonList]) : bool
  (match checks
    [(JsonListNil) true]
    [(JsonListCons head rest)
      (if (pr-check-entry-complete? head)
        (pr-check-list-complete? rest)
        false)]))

;;; Missing or empty `statusCheckRollup` means the PR has no checks and remains
;;; eligible. Only explicitly pending/running entries are skipped.
(define (pr-checks-complete? [item : Json]) : bool
  (match (json-object-get item "statusCheckRollup")
    [(JsonFound found)
      (match found
        [(JsonArray entries) (pr-check-list-complete? entries)]
        [_ true])]
    [(JsonMissing) true]))

;;; Build an issue candidate, classifying ready-for-implementation vs triage and
;;; adding the priority bonus.
(define (issue-candidate [item : Json]) : Candidate
  (let
    [labels : JsonList (issue-label-list item)]
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

;;; Map a JSON array of PR objects to candidates, preserving source order.
(define (pr-candidates [items : JsonList]) : CandList
  (match items
    [(JsonListNil) (CandNil)]
    [(JsonListCons head rest)
      (let
        [tail : CandList (pr-candidates rest)]
        (if (pr-checks-complete? head)
          (CandCons (pr-candidate head) tail)
          tail))]))

;;; Map a JSON array of issue objects to candidates, preserving source order.
(define (issue-candidates [items : JsonList]) : CandList
  (match items
    [(JsonListNil) (CandNil)]
    [(JsonListCons head rest)
      (CandCons (issue-candidate head) (issue-candidates rest))]))

;;; Concatenate two candidate lists, preserving order.
(define (cand-append [front : CandList] [back : CandList]) : CandList
  (match front
    [(CandNil) back]
    [(CandCons head rest) (CandCons head (cand-append rest back))]))

;;; Look up the JSON array stored at `field`, or an empty list when absent.
(define (json-field-array [value : Json] [field : String]) : JsonList
  (match (json-object-get value field)
    [(JsonFound found)
      (match found
        [(JsonArray entries) entries]
        [_ (JsonListNil)])]
    [(JsonMissing) (JsonListNil)]))

;;; Build the full candidate list: PR candidates first, then issue candidates.
(define (build-candidates [root : Json]) : CandList
  (cand-append
    (pr-candidates (json-field-array root "prs"))
    (issue-candidates (json-field-array root "issues"))))

;;; Build the weight list from candidates, preserving order so a chosen weight
;;; index maps back to the candidate at the same position.
(define (cand-weights [cands : CandList]) : RandomWeightList
  (match cands
    [(CandNil) (random-weight-list-empty)]
    [(CandCons head rest)
      (random-weight-list-cons (struct-get head weight) (cand-weights rest))]))

;;; Return the candidate at zero-based `index`, or a sentinel triage candidate
;;; when out of range (should not happen for a valid weighted index).
(define (cand-nth [cands : CandList] [index : i64]) : Candidate
  (match cands
    [(CandNil) (Candidate kind-triage 0 "" research-weight)]
    [(CandCons head rest)
      (if (= index 0)
        head
        (cand-nth rest (- index 1)))]))

;;; Number of candidates in a list.
(define (cand-count [cands : CandList]) : i64
  (match cands
    [(CandNil) 0]
    [(CandCons _ rest) (+ 1 (cand-count rest))]))

(test
  chooser-skips-incomplete-pr-checks
  (match (json-parse
    "{\"prs\":[{\"number\":1,\"title\":\"Draft without checks\",\"isDraft\":true},{\"number\":2,\"title\":\"Empty checks\",\"statusCheckRollup\":[]},{\"number\":3,\"title\":\"Completed checks\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"COMPLETED\",\"conclusion\":\"FAILURE\"}]},{\"number\":4,\"title\":\"Running checks\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"IN_PROGRESS\"}]},{\"number\":5,\"title\":\"Pending status\",\"statusCheckRollup\":[{\"__typename\":\"StatusContext\",\"state\":\"PENDING\"}]},{\"number\":6,\"title\":\"Failed status\",\"statusCheckRollup\":[{\"__typename\":\"StatusContext\",\"state\":\"FAILURE\"}]}],\"issues\":[{\"number\":7,\"title\":\"Fallback issue\",\"labels\":[]}]}")
    [(OkJson root)
      (let
        [cands : CandList (build-candidates root)]
        (begin
          (if (= (cand-count cands) 5)
            unit
            (panic "expected only complete/no-check PRs plus issue"))
          (if (= (struct-get (cand-nth cands 0) number) 1)
            unit
            (panic "draft no-check PR should remain eligible"))
          (if (= (struct-get (cand-nth cands 1) number) 2)
            unit
            (panic "empty check rollup should remain eligible"))
          (if (= (struct-get (cand-nth cands 2) number) 3)
            unit
            (panic "completed check run should remain eligible"))
          (if (= (struct-get (cand-nth cands 3) number) 6)
            unit
            (panic "terminal legacy status should remain eligible"))
          (if (= (struct-get (cand-nth cands 4) number) 7)
            unit
            (panic "issue should remain after skipped PRs"))))]
    [(ErrJson _) (panic "test JSON should parse")]))

(test
  chooser-p0-label-takes-precedence-over-p1
  (match (json-parse
    "{\"prs\":[],\"issues\":[{\"number\":10,\"title\":\"Both priorities\",\"labels\":[{\"name\":\"ready-for-implementation\"},{\"name\":\"p1\"},{\"name\":\"p0\"}]},{\"number\":11,\"title\":\"P1 only\",\"labels\":[{\"name\":\"ready-for-implementation\"},{\"name\":\"p1\"}]}]}")
    [(OkJson root)
      (let
        [cands : CandList (build-candidates root)]
        (begin
          (if (= (cand-count cands) 2)
            unit
            (panic "expected two issue candidates"))
          (if (=
            (struct-get (cand-nth cands 0) weight)
            (+ implement-weight p0-priority-bonus))
            unit
            (panic "issue with p0 and p1 should use p0 priority"))
          (if (=
            (struct-get (cand-nth cands 1) weight)
            (+ implement-weight p1-priority-bonus))
            unit
            (panic "issue with only p1 should use p1 priority"))))]
    [(ErrJson _) (panic "test JSON should parse")]))

;;; The action verb for a candidate kind.
(define (action-name [kind : i64]) : String
  (if (= kind kind-pr)
    "review"
    (if (= kind kind-ready)
      "implement"
      "research/triage")))

;;; The GitHub object word for a candidate kind.
(define (github-kind [kind : i64]) : String
  (if (= kind kind-pr)
    "pr"
    "issue"))

;;; Render one candidate as the chooser's action line (without trailing newline).
(define (candidate-line [cand : Candidate]) : String
  (string-append
    (string-append (action-name (struct-get cand kind)) " ")
    (string-append
      (string-append (github-kind (struct-get cand kind)) " #")
      (string-append
        (int->string (struct-get cand number))
        (string-append ": " (struct-get cand title))))))

;;; Choose one candidate from the input JSON, returning an error message on
;;; invalid input or an empty candidate set.
(define (choose-candidate [text : String]) : ChooserResult
  (match (json-parse text)
    [(ErrJson message)
      (ChooserErr (string-append "Error: invalid JSON: " message))]
    [(OkJson root)
      (let
        [cands : CandList (build-candidates root)]
        (if (= (cand-count cands) 0)
          (ChooserErr "Error: no eligible candidates were provided")
          (match (random-system-seed)
            [(ErrSystemSeed err)
              (ChooserErr
                (match err
                  [(RandomSystemSeedUnavailable message)
                    (string-append "Error: " message)]))]
            [(OkSystemSeed seed)
              (match (random-weighted-index
                (random-seed seed)
                (cand-weights cands))
                [(ErrRandomWeightedIndex message)
                  (ChooserErr (string-append "Error: " message))]
                [(OkRandomWeightedIndex _ index)
                  (ChooserOk (cand-nth cands index))])])))]))

(define (main) : i64
  (match (choose-candidate (read-all-stdin))
    [(ChooserErr message)
      (begin
        (print-error message)
        1)]
    [(ChooserOk cand)
      (begin
        (print-string (candidate-line cand))
        (print-newline)
        0)]))