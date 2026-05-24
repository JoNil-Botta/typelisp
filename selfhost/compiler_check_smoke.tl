;; compiler_check_smoke.tl - Runnable smoke for virtual-source check helpers.

(import "compiler_check_core.tl")

(define (main) : i64
  (compiler-check-self-test))