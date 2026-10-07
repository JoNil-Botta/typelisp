;; compiler_state_schema_field_type_reject.tl - a packed-state field is read
;; only through its typed accessor (#7021), so reading it as another type is a
;; type error rather than an unsafe access through a mismatched pointer type.
(import compiler_state_schema as state_schema)
(import stdlib.hash)

(defstruct Probe
  (address i64))

(defstruct ProbeSeed
  (start i64))

(state_schema.compiler-state-directory-schema
  probe
  Probe
  ProbeSeed
  seed
  address
  [count : i64 seed.start]
  [ready : bool false])

(define (main) : i64
  (let
    [p : Probe (probe-from-seed (ProbeSeed 1))]
    [text : String (probe-count p)]
    (string-length text)))