;; The expected enum type resolves an imported enum's bare variants, even when
;; a local enum declares the same names.
(import variant_resolution_provider as provider)

(defenum Local
  (Pass i64)
  (Fail i64))

(define (passed [value : i64]) : provider.Outcome
  (Pass value))

(define (main) : i64
  (+ (provider.outcome-value (passed 40)) (provider.outcome-value (Pass 2))))