;; compiler_state_schema_ok.tl - a packed-state schema (#7021) derives every
;; slot, typed accessor, initializer and fingerprint from one field list, and
;; a second schema with one field inserted shows each derived item following
;; the insertion. Each check returns its own code; all passing exits 42.
(import compiler_state_schema as state_schema)
(import stdlib.hash)

(defstruct Probe
  (address i64))

(defstruct Wider
  (address i64))

(defstruct ProbeSeed
  (start i64)
  (label String))

(define (probe-text-fingerprint [text : String]) : i64
  (string-length text))

(state_schema.compiler-state-directory-schema
  probe
  Probe
  ProbeSeed
  seed
  address
  [count : i64 seed.start]
  [label : String (observed-by probe-text-fingerprint seed.label)]
  [owner : i64 (unobserved address)]
  [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
  [extra : i64 (unobserved 7)])

;; The same fields with `flag` inserted second.
(state_schema.compiler-state-directory-schema
  wider
  Wider
  ProbeSeed
  seed
  address
  [count : i64 seed.start]
  [flag : bool true]
  [label : String (observed-by probe-text-fingerprint seed.label)]
  [owner : i64 (unobserved address)]
  [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
  [extra : i64 (unobserved 7)])

(define (main) : i64
  (let
    [p : Probe (probe-from-seed (ProbeSeed 40 "abc"))]
    [q : Probe (probe-from-seed (ProbeSeed 40 "abc"))]
    [w : Wider (wider-from-seed (ProbeSeed 40 "abc"))]
    [before : (__tl_dyn-array i64) (probe-fingerprints p)]
    [wide : (__tl_dyn-array i64) (wider-fingerprints w)]
    (probe-set-count! p 41)
    (probe-set-extra! p 9)
    (let
      [after : (__tl_dyn-array i64) (probe-fingerprints p)]
      [other : (__tl_dyn-array i64) (probe-fingerprints q)]
      (cond
        ;; Slots and fingerprints follow the field list; unobserved fields
        ;; take a slot but no fingerprint.
        [(not (= probe-slot-count 5)) 1]
        [(not (= wider-slot-count 6)) 2]
        [(not (= (array-length before) 3)) 3]
        [(not (= (array-length wide) 4)) 4]
        ;; Initializers see the seed and the new directory's address.
        [(not (= (probe-count q) 40)) 5]
        [(not (= (probe-owner p) p.address)) 6]
        [(not (= (string-length (probe-label p)) 3)) 7]
        [(not (= (probe-extra q) 7)) 8]
        [(not (= (array-length (probe-items p)) 2)) 9]
        ;; `observed-by` fingerprints through its function.
        [(not (= (array-ref before 1) 3)) 10]
        ;; A write changes its own cell's fingerprint and no other field.
        [(= (array-ref before 0) (array-ref after 0)) 11]
        [(not (= (array-ref before 1) (array-ref after 1))) 12]
        [(not (= (array-ref before 2) (array-ref after 2))) 13]
        [(not (= (probe-count p) 41)) 14]
        [(not (= (probe-extra p) 9)) 15]
        [(not (= (probe-owner p) p.address)) 16]
        ;; Each state owns its cells.
        [(not (= (array-ref other 0) (array-ref before 0))) 17]
        [(not (= (probe-count q) 40)) 18]
        ;; The inserted field shifts the later fingerprints.
        [(not (wider-flag w)) 19]
        [(not (= (array-ref wide 2) (array-ref before 1))) 20]
        [(not (= (wider-owner w) w.address)) 21]
        [else 42]))))