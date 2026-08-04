;; The generated declaration contains a fixed-array shape in both branches;
;; only the bool branch intentionally supplies the wrong element type.
(import tests.proof_reuse_safety_provider as provider)
(import (provider.proof-reuse-reflection-fixed-shape i64) as fixed_i64)
(import (provider.proof-reuse-reflection-fixed-shape bool) as fixed_bool)

(define (main) : i64
  42)