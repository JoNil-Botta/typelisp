;; compiler_spmd_package_abi_smoke.tl - callable backend and ABI diagnostics.
(import "../compiler_lower.tl")

(define (main) : i64
  (if (compiler-lower-spmd-package-callable-abi-errors-ok?)
    42
    1))