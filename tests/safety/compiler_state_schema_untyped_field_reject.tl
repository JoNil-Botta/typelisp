;; compiler_state_schema_untyped_field_reject.tl - every packed-state field
;; declares its type (#7021).
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
  [count seed.start])

(define (main) : i64
  (probe-count (probe-from-seed (ProbeSeed 1))))