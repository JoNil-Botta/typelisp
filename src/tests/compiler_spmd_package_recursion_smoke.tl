;; compiler_spmd_package_recursion_smoke.tl - callable recursion diagnostics.
(import "../compiler_lower.tl")

(define (main) : i64
  (if (compiler-lower-spmd-package-callable-recursion-errors-ok?)
    42
    1))