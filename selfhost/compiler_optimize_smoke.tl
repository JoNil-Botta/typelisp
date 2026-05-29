;; compiler_optimize_smoke.tl - Runnable smoke for compiler_optimize.tl
;; (#543 constant folding, #544 dead-code elimination, #546 common
;; subexpression elimination, #545 copy propagation, #924 strength reduction,
;; #925 typed constant/cast folding, #926 CFG simplification, #930 bounds-check
;; elimination, #1347 CFG/dominance/SSA verification, opt-level policy, and
;; #923 fixed-point iteration).
;;
;; Folds constant arithmetic and typed scalar operations into `Mov` literals,
;; reduces safe algebraic identities, eliminates an unused pure temporary,
;; eliminates a repeated pure expression, propagates block-local copies, removes
;; duplicate proven bounds checks, simplifies constant control flow, validates
;; CFG/dominance/SSA utility invariants, selects optimization policies by level,
;; and reruns the pass pipeline to a fixed point; returns 42 only when every
;; self-test passes.
(import "compiler_optimize.tl")

(define (main) : i64
  (if (= (compiler-optimize-self-test) 42)
    (if (= (compiler-optimize-typed-fold-self-test) 42)
      (if (= (compiler-optimize-strength-self-test) 42)
        (if (= (compiler-optimize-dce-self-test) 42)
          (if (= (compiler-optimize-dce-mem-self-test) 42)
            (if (= (compiler-optimize-cse-self-test) 42)
              (if (= (compiler-optimize-copy-self-test) 42)
                (if (= (compiler-optimize-bounds-self-test) 42)
                  (if (= (compiler-optimize-cfg-self-test) 42)
                    (if (= (compiler-optimize-ssa-self-test) 42)
                      (if (= (compiler-optimize-level-self-test) 42)
                        (if (= (compiler-optimize-fixed-point-self-test) 42)
                          (if (= (compiler-optimize-global-dce-self-test) 42)
                            (if (=
                              (compiler-optimize-aggregate-candidate-self-test)
                              42)
                              (compiler-optimize-spans-self-test)
                              1)
                            1)
                          1)
                        1)
                      1)
                    1)
                  1)
                1)
              1)
            1)
          1)
        1)
      1)
    1))