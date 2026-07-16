;; compiler_spmd_package_validation_smoke.tl - callable class/body diagnostics.
(import "../compiler_lower_package_tests.tl")

(define (main) : i64
  (if (compiler-lower-spmd-package-callable-validation-errors-ok?)
    42
    1))