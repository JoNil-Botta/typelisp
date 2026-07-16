;; compiler_spmd_package_callable_smoke.tl - package SPMD callable lowering.
(import "../compiler_lower_package_tests.tl")

(define (main) : i64
  (if (compiler-lower-spmd-package-callable-tests-ok?)
    42
    1))