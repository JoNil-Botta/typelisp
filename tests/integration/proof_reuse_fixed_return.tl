;; A fixed i64 return boundary must remain concrete for a u8 parameter.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-fixed-return i64) as fixed_i64)
(import (provider.proof-reuse-fixed-return u8) as fixed_u8)

(define (main) : i64
  42)