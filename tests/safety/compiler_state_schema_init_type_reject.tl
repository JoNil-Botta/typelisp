;; compiler_state_schema_init_type_reject.tl - a packed-state field's
;; initializer is checked against the field's declared type (#7021).
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
  [count : i64 "zero"])

(define (main) : i64
  (probe-count (probe-from-seed (ProbeSeed 1))))