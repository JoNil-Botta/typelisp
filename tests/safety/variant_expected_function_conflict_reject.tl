;; The imported module's bare `Fail` names both its own function and the
;; expected enum's variant (variant_resolution_function_conflict.tl).
(import variant_resolution_provider as provider)
(import variant_resolution_function_conflict as conflict)

(define (main) : i64
  (provider.outcome-value (conflict.failed 42)))