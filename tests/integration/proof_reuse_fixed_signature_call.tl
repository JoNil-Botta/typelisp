;; A fixed i64 callee must not be reused for the later u8 identity even
;; though the caller's own AST is an exact identity substitution.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-fixed-signature-call i64) as fixed_i64)
(import (provider.proof-reuse-fixed-signature-call u8) as fixed_u8)

(define (main) : i64
  42)