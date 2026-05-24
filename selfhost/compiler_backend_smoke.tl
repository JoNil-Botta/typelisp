;; compiler_backend_smoke.tl - Runnable smoke for compiler_backend.tl (#447).
(import "compiler_backend.tl")

(define (main) : i64
  (compiler-backend-self-test))