;; Per-declaration proof reuse must remain available when sibling catalog
;; counts differ between generated identities.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-partial-catalog i64 "extra") as partial_i64)
(import (provider.proof-reuse-partial-catalog i32 "base") as partial_i32)

(define partial-i64-value : i64
  (partial_i64.identity 7))
(define partial-i32-value : i32
  (partial_i32.identity 7))

(define (main) : i64
  (+ partial-i64-value (cast partial-i32-value : i64)))