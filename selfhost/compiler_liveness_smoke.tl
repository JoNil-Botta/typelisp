;; compiler_liveness_smoke.tl - Runnable smoke for compiler_liveness.tl (#553).
(import "compiler_liveness.tl")

(define (main) : i64
  (compiler-live-self-test))