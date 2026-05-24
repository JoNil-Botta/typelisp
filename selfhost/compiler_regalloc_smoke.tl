;; compiler_regalloc_smoke.tl - Runnable smoke for compiler_regalloc.tl (#554).
(import "compiler_regalloc.tl")

(define (main) : i64
  (compiler-regalloc-self-test))