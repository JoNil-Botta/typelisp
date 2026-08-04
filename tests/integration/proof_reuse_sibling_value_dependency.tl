;; Referenced sibling values must not be reused across generated identities.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-sibling-value-dependency i64 "integer") as first)
(import (provider.proof-reuse-sibling-value-dependency i32 "boolean") as second)

(define (main) : i64
  0)