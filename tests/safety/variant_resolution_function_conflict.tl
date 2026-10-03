;; A module function named like the expected enum's variant makes the bare
;; name ambiguous; variant_expected_function_conflict_reject.tl loads this
;; module.
(import variant_resolution_provider as provider)

;; lint-allow: function-name-case -- spells the provider's variant on purpose
(define (Fail [value : i64]) : provider.Outcome
  (provider.Outcome.Fail value))

(define (failed [value : i64]) : provider.Outcome
  (Fail value))