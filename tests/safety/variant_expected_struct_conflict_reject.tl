;; The imported module's bare `Pass` names both its struct constructor and
;; the expected enum's variant (variant_resolution_conflict.tl).
(import variant_resolution_provider as provider)
(import variant_resolution_conflict as conflict)

(define (main) : i64
  (provider.outcome-value (conflict.passed 42)))