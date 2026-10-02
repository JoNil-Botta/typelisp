;; A struct constructor named like the expected enum's variant makes the bare
;; name ambiguous; variant_expected_struct_conflict_reject.tl loads this module.
(import variant_resolution_provider as provider)

(defstruct Pass
  (value i64))

(define (passed [value : i64]) : provider.Outcome
  (Pass value))