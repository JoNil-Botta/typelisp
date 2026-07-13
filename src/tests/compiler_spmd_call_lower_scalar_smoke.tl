;; compiler_spmd_call_lower_scalar_smoke.tl - Scalar private SPMD-call lowering.
(import "../compiler_lower.tl")

(define (main) : i64
  (if (compiler-lower-spmd-scalar-call-shape-ok?)
    42
    1))