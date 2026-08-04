;; A fixed i64 let annotation on a T-typed value must remain concrete for u8.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-fixed-local-annotation i64) as fixed_i64)
(import (provider.proof-reuse-fixed-local-annotation u8) as fixed_u8)

(define (main) : i64
  42)