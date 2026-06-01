;; compiler_optimize_smoke.tl - Runnable smoke for compiler_optimize.tl
;; (#543 constant folding, #544 dead-code elimination, #546 common
;; subexpression elimination, #545 copy propagation, #924 strength reduction,
;; #925 typed constant/cast folding, #926 CFG simplification, #930 bounds-check
;; elimination, #1347 CFG/dominance/SSA verification, opt-level policy, and
;; #923 fixed-point iteration, #1348 sparse conditional constant propagation,
;; #1489 aggregate stack promotion, and #1349 global value
;; numbering/cross-block copy propagation).
;;
;; Folds constant arithmetic and typed scalar operations into `Mov` literals,
;; reduces safe algebraic identities, eliminates an unused pure temporary,
;; eliminates a repeated pure expression, propagates block-local copies, removes
;; duplicate proven bounds checks, simplifies constant control flow, validates
;; CFG/dominance/SSA utility invariants, stack-promotes safe local aggregate
;; storage, selects optimization policies by level, reruns the pass pipeline to
;; a fixed point, and removes dominated repeated scalar expressions across
;; blocks; returns 42 only when every self-test passes.
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
                  (if (= (compiler-optimize-sccp-self-test) 42)
                    (if (= (compiler-optimize-global-value-number-self-test) 42)
                      (if (= (compiler-optimize-cfg-self-test) 42)
                        (if (= (compiler-optimize-ssa-self-test) 42)
                          (if (= (compiler-optimize-level-self-test) 42)
                            (if (= (compiler-optimize-fixed-point-self-test) 42)
                              (if (=
                                (compiler-optimize-global-dce-self-test)
                                42)
                                (if (=
                                  (compiler-optimize-aggregate-promote-self-test)
                                  42)
                                  (if (=
                                    (compiler-optimize-aggregate-sroa-self-test)
                                    42)
                                    (if (=
                                      (compiler-optimize-spans-self-test)
                                      42)
                                      (if (=
                                        (compiler-optimize-gvn-self-test)
                                        42)
                                        (compiler-optimize-alias-self-test)
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
              1)
            1)
          1)
        1)
      1)
    1))