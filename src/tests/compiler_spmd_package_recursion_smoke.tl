;; compiler_spmd_package_recursion_smoke.tl - callable recursion diagnostics.
(import compiler_lower_package_tests)

(define (main) : i64
  (if (compiler_lower_package_tests.compiler-lower-spmd-package-callable-recursion-errors-ok?)
    42
    1))