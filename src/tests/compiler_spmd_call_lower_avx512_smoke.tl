;; compiler_spmd_call_lower_avx512_smoke.tl - AVX-512 private SPMD-call lowering.
(import "../compiler_lower_tests.tl")

(define (main) : i64
  (if (compiler-lower-spmd-out-of-line-call-shape-ok?)
    42
    1))