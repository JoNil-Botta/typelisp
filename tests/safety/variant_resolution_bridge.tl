;; Imports the provider so a caller of the bridge loads it without importing it.
(import variant_resolution_provider as provider)

(define (passed [value : i64]) : provider.Outcome
  (provider.Outcome.Pass value))