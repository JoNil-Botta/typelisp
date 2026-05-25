;;;; work-queue-chooser/chooser.tl - TypeLisp port of the Rust work-queue chooser (#794).
;;;;
;;;; Reads the combined `{"prs":[...],"issues":[...]}` JSON from stdin, classifies
;;;; each entry, weights it (PR review = 30, ready-for-implementation = 10,
;;;; research/triage = 1, +3 for a p0/p1 label), makes a seeded weighted pick, and
;;;; prints one action line:
;;;;
;;;;   review pr #N: Title
;;;;   implement issue #N: Title
;;;;   research/triage issue #N: Title
;;;;
;;;; Unlike the Rust tool (non-deterministic `rand::thread_rng`), the selection is
;;;; deterministic from a seed: pass it as the first argument (e.g. a `$RANDOM`
;;;; value) so repeated invocations vary. With no argument a fixed fallback seed
;;;; is used. JSON parsing uses `stdlib/json.tl`; weighting uses `stdlib/random.tl`.
;;;;
;;;; Usage: `typelisp run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib -- <seed>`
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

(define priority-bonus : i64
  3)

(define fallback-seed : i64
  2463534242)

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

;;; A label list carries a priority label when it has p0 or p1.
(define (label-list-priority? [labels : JsonList]) : bool
  (if (label-list-has? labels "p0")
    true
    (label-list-has? labels "p1")))

;;; Build a PR candidate (kind = review, no labels considered).
(define (pr-candidate [item : Json]) : Candidate
  (Candidate
    kind-pr
    (json-field-number item "number")
    (json-field-string item "title")
    review-weight))

;;; Build an issue candidate, classifying ready-for-implementation vs triage and
;;; adding the priority bonus.
(define (issue-candidate [item : Json]) : Candidate
  (let
    [labels : JsonList (issue-label-list item)]
    [ready : bool (label-list-has? labels "ready-for-implementation")]
    [bonus : i64 (if (label-list-priority? labels) priority-bonus 0)]
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
      (CandCons (pr-candidate head) (pr-candidates rest))]))

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

;;; The seed to use: first argument when present, otherwise the fallback.
(define (chooser-seed) : i64
  (if (> (arg-count) 1)
    (string->int (arg 1))
    fallback-seed))

;;; Print the chosen candidate's action line; print an error and return 1 on
;;; failure, 0 on success.
(define (run-chooser [text : String]) : i64
  (match (json-parse text)
    [(ErrJson message)
      (begin
        (print-error (string-append "Error: invalid JSON: " message))
        1)]
    [(OkJson root)
      (let
        [cands : CandList (build-candidates root)]
        (if (= (cand-count cands) 0)
          (begin
            (print-error "Error: no eligible candidates were provided")
            1)
          (match (random-weighted-index (random-seed (chooser-seed)) (cand-weights cands))
            [(ErrRandomWeightedIndex message)
              (begin
                (print-error (string-append "Error: " message))
                1)]
            [(OkRandomWeightedIndex _ index)
              (begin
                (print-string (candidate-line (cand-nth cands index)))
                (print-newline)
                0)])))]))

(define (main) : i64
  (run-chooser (read-all-stdin)))
