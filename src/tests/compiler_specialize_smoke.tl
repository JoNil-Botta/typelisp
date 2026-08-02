;; compiler_specialize_smoke.tl - Native smoke for selfhost specialization.
(import compiler_specialize)

(define (main) : i64
  (if (= (compiler_specialize.compiler-specialize-self-test) 1)
    42
    1))