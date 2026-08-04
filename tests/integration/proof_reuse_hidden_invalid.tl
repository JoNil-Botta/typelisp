;; First-identity hidden invalid output: demand pruning must not suppress the
;; concrete check of this unreferenced declaration.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-hidden-invalid u8) as hidden_invalid)

(define (main) : i64
  42)