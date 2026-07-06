;; compiler_specialize_smoke.tl - Native smoke for selfhost specialization.
(import "../compiler_specialize.tl")

(define (main) : i64
  (if (= (compiler-specialize-self-test) 1)
    42
    1))