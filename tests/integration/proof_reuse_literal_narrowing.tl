;; A valid i64 seed followed by an invalid u8 identity must fall back to a
;; concrete check of the later generated declaration.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-literal-narrowing i64) as literal_i64)
(import (provider.proof-reuse-literal-narrowing u8) as literal_u8)

(define (main) : i64
  42)