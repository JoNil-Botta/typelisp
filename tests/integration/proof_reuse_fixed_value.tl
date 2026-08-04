;; A fixed i64 value must not satisfy the later u8 return declaration through
;; proof reuse.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-fixed-value i64) as fixed_i64)
(import (provider.proof-reuse-fixed-value u8) as fixed_u8)

(define (main) : i64
  42)