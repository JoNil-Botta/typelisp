;; Equality-sensitive declarations must not be reused across identities even
;; when both identities typecheck successfully.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-equality-sensitive i64) as equality_i64)
(import (provider.proof-reuse-equality-sensitive u8) as equality_u8)

(define (main) : i64
  42)