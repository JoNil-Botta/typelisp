;; Function values are not cloneable; the second identity must remain concrete.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-uncloneable-clone i64) as clone_i64)
(import (provider.proof-reuse-uncloneable-clone (-> i64 i64)) as clone_function)

(define (main) : i64
  42)