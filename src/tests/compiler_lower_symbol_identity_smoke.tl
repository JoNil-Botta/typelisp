;; compiler_lower_symbol_identity_smoke.tl - Typed lowerer symbol selection.
(import compiler_driver_smoke_tests)

(define (main) : i64
  (compiler_driver_smoke_tests.compiler-lower-symbol-identity-smoke-main))