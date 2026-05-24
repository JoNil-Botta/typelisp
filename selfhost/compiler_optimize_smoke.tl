;; compiler_optimize_smoke.tl - Runnable smoke for compiler_optimize.tl
;; (#543 constant folding, #544 dead-code elimination).
;;
;; Folds a constant arithmetic instruction into a `Mov` literal, and eliminates
;; an unused pure temporary; returns 42 only when both self-tests pass.

(import "compiler_optimize.tl")

(define (main) : i64
  (if (= (compiler-optimize-self-test) 42)
      (compiler-optimize-dce-self-test)
      1))
