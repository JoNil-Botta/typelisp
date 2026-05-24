;; compiler_optimize_smoke.tl - Runnable smoke for compiler_optimize.tl (#543).
;;
;; Folds a constant arithmetic instruction and verifies it became a `Mov`
;; literal with the correct value (returns 42 on success).

(import "compiler_optimize.tl")

(define (main) : i64
  (compiler-optimize-self-test))
