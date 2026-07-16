;; compiler_spmd_package_mutual_recursion_smoke.tl - mutual recursion diagnostic.
(import "../compiler_lower_package_tests.tl")

(define (main) : i64
  (if (compiler-lower-spmd-package-callable-mutual-recursion-error-ok?)
    42
    1))