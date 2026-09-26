;; compiler_specialize_smoke.tl - Native smoke for selfhost specialization.
(import compiler_specialize_tests as spec_tests)

(define (main) : i64
  (if (= (spec_tests.compiler-specialize-self-test) 1)
    42
    1))