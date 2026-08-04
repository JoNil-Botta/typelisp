;; Arithmetic is valid for the family seed but not for bool.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-bool-arithmetic i64) as arithmetic_i64)
(import (provider.proof-reuse-bool-arithmetic bool) as arithmetic_bool)

(define (main) : i64
  42)