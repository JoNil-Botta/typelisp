;; compiler_check_smoke.tl - Runnable smoke for virtual-source check helpers.
(import compiler_check_tests)

(define (main) : i64
  (if (compiler_check_tests.compiler-check-tests-ok?)
    42
    1))