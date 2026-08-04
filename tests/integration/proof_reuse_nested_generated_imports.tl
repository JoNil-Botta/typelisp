;; The outer generated module imports its own inner generated module.  The
;; inner u8 declaration remains hidden from entry demand but must be checked.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-nested-outer i64) as nested_i64)
(import (provider.proof-reuse-nested-outer u8) as nested_u8)

(define (main) : i64
  42)