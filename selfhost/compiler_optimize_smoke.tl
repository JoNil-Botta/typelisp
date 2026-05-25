;; compiler_optimize_smoke.tl - Runnable smoke for compiler_optimize.tl
;; (#543 constant folding, #544 dead-code elimination, #546 common
;; subexpression elimination, #545 copy propagation, #924 strength reduction).
;;
;; Folds a constant arithmetic instruction into a `Mov` literal, reduces safe
;; algebraic identities, eliminates an unused pure temporary, eliminates a
;; repeated pure expression, and propagates block-local copies; returns 42 only
;; when every self-test passes.
(import "compiler_optimize.tl")

(define (main) : i64
  (if (= (compiler-optimize-self-test) 42)
    (if (= (compiler-optimize-strength-self-test) 42)
      (if (= (compiler-optimize-dce-self-test) 42)
        (if (= (compiler-optimize-dce-mem-self-test) 42)
          (if (= (compiler-optimize-cse-self-test) 42)
            (compiler-optimize-copy-self-test)
            1)
          1)
        1)
      1)
    1))